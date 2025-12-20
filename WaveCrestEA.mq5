//+------------------------------------------------------------------+
//| WaveCrestEA v1.228 - Added Trailing Stop Feature                |
//+------------------------------------------------------------------+
#property copyright "WaveCrestEA"
#property version   "1.228"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

input int    MACD_Fast        = 85;
input int    MACD_Slow        = 100;
input int    MACD_Signal      = 50;
input int    ATR_Period       = 14;
input double ATR_Mult         = 2.0;
input double TP_Mult          = 3.9;
input double RiskPercent      = 2.0;      // Base risk percent of free margin per trade
input double FixedLot         = 0.0;      // If > 0, use as base lot (step-up still applies)
input int    MaxDoublings     = 11;        // Max consecutive loss step-ups
input double LossMultiplier   = 1.05;      // Multiplier applied per consecutive loss
input double GapPct           = 0.04;
input double RSI_Buy_Th       = 50.0;
input double RSI_Sell_Th      = 50.0;
input bool   Enable_TrailingStop = false; // Enable/disable trailing stop feature
input double TrailingStop_ATR_Mult = 1.5;  // ATR multiplier for trailing stop distance

const bool UseGlobalGuard   = true;
const bool ClearGVOnInit    = true;
const int MIN_SL_MOVEMENT_POINTS = 10; // Minimum points SL must move to update

int macdHandle = INVALID_HANDLE;
int atrHandle  = INVALID_HANDLE;
int rsiHandle  = INVALID_HANDLE;

datetime lastProcessedBar = 0;

bool armedBuy = false;
bool armedSell = false;
int armedBuyID = 0;
int armedSellID = 0;
int currentArmCounter = 0;
int lastFiredArmID = 0;

int consecutiveLosses = 0;
ulong lastPositionTicket = 0;
bool positionWasOpen = false;
bool trailingStopActivated = false; // Track if trailing stop has been activated
double positionOpenPrice = 0.0;     // Store position open price
bool positionIsBuy = false;         // Track if position is buy or sell

string ts(datetime t)
{
   if(t <= 0) return("NA");
   return(TimeToString(t, TIME_DATE|TIME_SECONDS));
}

double PointSize()
{
   double p = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(p < 0.000001) p = 0.00001;
   return p;
}

double CalcLotsByRisk(double entry, double stopLoss, double riskPct)
{
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double minLot    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);

   double riskMoney = (riskPct / 100.0) * freeMargin;
   double slTicks = MathAbs(entry - stopLoss) / tickSize;
   if(slTicks < 0.5) return minLot;

   double lots = riskMoney / (slTicks * tickValue);
   if(lotStep <= 0) return minLot;
   lots = MathFloor(lots / lotStep) * lotStep;
   if(lots < minLot) lots = minLot;
   if(lots > maxLot) lots = maxLot;
   return lots;
}

double CalcLotsWithStepUp(double entry, double stopLoss)
{
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   int doublings = consecutiveLosses;
   if(doublings < 0) doublings = 0;
   if(doublings > MaxDoublings) doublings = MaxDoublings;

   double safeMultiplier = LossMultiplier;
   if(safeMultiplier < 1.0) safeMultiplier = 1.0;

   double multiplier = MathPow(safeMultiplier, doublings);
   double lots = 0.0;

   if(FixedLot > 0.0)
   {
      lots = FixedLot * multiplier;
      if(lotStep > 0) lots = MathFloor(lots / lotStep) * lotStep;
      if(lots < minLot) lots = minLot;
      if(lots > maxLot) lots = maxLot;
      PrintFormat("%s SIZING (FixedLot): baseLot=%.2f consecutiveLosses=%d multiplier=%.2f finalLots=%.2f",
                  ts(TimeCurrent()), FixedLot, consecutiveLosses, multiplier, lots);
   }
   else
   {
      double effectiveRisk = RiskPercent * multiplier;
      lots = CalcLotsByRisk(entry, stopLoss, effectiveRisk);
      PrintFormat("%s SIZING (RiskPct): baseRisk=%.2f%% consecutiveLosses=%d multiplier=%. 2f effectiveRisk=%. 2f%% lots=%.2f",
                  ts(TimeCurrent()), RiskPercent, consecutiveLosses, multiplier, effectiveRisk, lots);
   }
   
   return lots;
}

string GvNameLastOrder()
{
   int login = (int)AccountInfoInteger(ACCOUNT_LOGIN);
   return(StringFormat("WaveCrest_LastOrderBar_%s_%d", _Symbol, login));
}

string GvNameLastFiredArm()
{
   int login = (int)AccountInfoInteger(ACCOUNT_LOGIN);
   return(StringFormat("WaveCrest_LastFiredArm_%s_%d", _Symbol, login));
}

bool CreateHandles()
{
   if(macdHandle != INVALID_HANDLE) IndicatorRelease(macdHandle);
   if(atrHandle  != INVALID_HANDLE) IndicatorRelease(atrHandle);
   if(rsiHandle  != INVALID_HANDLE) IndicatorRelease(rsiHandle);

   macdHandle = iMACD(_Symbol, PERIOD_CURRENT, MACD_Fast, MACD_Slow, MACD_Signal, PRICE_CLOSE);
   atrHandle  = iATR(_Symbol, PERIOD_CURRENT, ATR_Period);
   rsiHandle  = iRSI(_Symbol, PERIOD_CURRENT, 14, PRICE_CLOSE);

   return (macdHandle != INVALID_HANDLE);
}

bool PlaceMarketOrder(bool isBuy, double lots, double sl, double tp, string comment)
{
   ResetLastError();
   bool ok = false;
   if(isBuy)
      ok = trade.Buy(lots, _Symbol, 0.0, sl, tp, comment);
   else
      ok = trade. Sell(lots, _Symbol, 0.0, sl, tp, comment);
   if(! ok)
   {
      int err = GetLastError();
      PrintFormat("%s WaveCrestEA: PlaceMarketOrder failed err=%d", ts(TimeCurrent()), err);
   }
   return ok;
}

void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   ulong dealTicket = trans. deal;
   if(dealTicket == 0) return;

   // Need to select the deal in history first
   if(! HistoryDealSelect(dealTicket)) return;

   string dsym = HistoryDealGetString(dealTicket, DEAL_SYMBOL);
   if(dsym != _Symbol) return;

   // Only process closing deals (DEAL_ENTRY_OUT), not opening deals
   long dealEntry = HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
   if(dealEntry != DEAL_ENTRY_OUT) return;

   double profit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
   
   // Reset trailing stop state when position closes
   trailingStopActivated = false;
   positionOpenPrice = 0.0;
   positionIsBuy = false;
   
   if(profit < 0.0)
   {
      consecutiveLosses++;
      if(consecutiveLosses > MaxDoublings) consecutiveLosses = MaxDoublings;
      PrintFormat("%s LOSS detected: profit=%.2f consecutiveLosses=%d", ts(TimeCurrent()), profit, consecutiveLosses);
   }
   else if(profit > 0.0)
   {
      PrintFormat("%s WIN detected: profit=%.2f resetting consecutiveLosses %d->0", ts(TimeCurrent()), profit, consecutiveLosses);
      consecutiveLosses = 0;
   }
}

int OnInit()
{
   PrintFormat("WaveCrestEA v1.228 init - RiskPercent=%.1f%% FixedLot=%.2f MaxDoublings=%d LossMultiplier=%.1f Enable_TrailingStop=%d", 
               RiskPercent, FixedLot, MaxDoublings, LossMultiplier, Enable_TrailingStop);
   if(ClearGVOnInit)
   {
      string gv1 = GvNameLastOrder();
      string gv2 = GvNameLastFiredArm();
      if(GlobalVariableCheck(gv1)) GlobalVariableDel(gv1);
      if(GlobalVariableCheck(gv2)) GlobalVariableDel(gv2);
      lastFiredArmID = 0;
   }
   CreateHandles();
   lastProcessedBar = 0;
   currentArmCounter = 0;
   armedBuy = false;
   armedSell = false;
   consecutiveLosses = 0;
   trailingStopActivated = false;
   positionOpenPrice = 0.0;
   positionIsBuy = false;
   positionWasOpen = PositionSelect(_Symbol);
   if(! ClearGVOnInit && GlobalVariableCheck(GvNameLastFiredArm()))
      lastFiredArmID = (int)GlobalVariableGet(GvNameLastFiredArm());
   EventSetTimer(1);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   if(macdHandle != INVALID_HANDLE) IndicatorRelease(macdHandle);
   if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
   if(rsiHandle != INVALID_HANDLE) IndicatorRelease(rsiHandle);
}

void OnTimer() { OnTick(); }

void ManageTrailingStop()
{
   if(!Enable_TrailingStop) return;
   if(!PositionSelect(_Symbol)) return;
   
   double currentPrice = PositionGetDouble(POSITION_PRICE_CURRENT);
   double positionSL = PositionGetDouble(POSITION_SL);
   double positionTP = PositionGetDouble(POSITION_TP);
   ulong positionTicket = PositionGetInteger(POSITION_TICKET);
   long posType = PositionGetInteger(POSITION_TYPE);
   
   // Get current ATR
   double atr = 0.0;
   if(atrHandle != INVALID_HANDLE)
   {
      double a[];
      ArraySetAsSeries(a, true);
      int copied = CopyBuffer(atrHandle, 0, 0, 2, a);
      if(copied >= 2 && ArraySize(a) >= 2) 
         atr = a[1];
      else if(copied < 2)
         return; // Cannot proceed without valid ATR
   }
   if(atr <= 0.0) return;
   
   double minImprovement = atr * ATR_Mult; // Minimum improvement threshold
   double trailingDistance = atr * TrailingStop_ATR_Mult; // Trailing stop distance
   
   if(posType == POSITION_TYPE_BUY)
   {
      // Check if price has moved past minimum improvement level
      if(!trailingStopActivated)
      {
         if(currentPrice >= positionOpenPrice + minImprovement)
         {
            trailingStopActivated = true;
            PrintFormat("%s TRAILING_STOP_ACTIVATED (BUY): price=%.5f openPrice=%.5f minImprovement=%.5f",
                       ts(TimeCurrent()), currentPrice, positionOpenPrice, minImprovement);
         }
      }
      
      // If trailing stop is activated, adjust SL
      if(trailingStopActivated)
      {
         double newSL = currentPrice - trailingDistance;
         if(newSL > positionSL + PointSize() * MIN_SL_MOVEMENT_POINTS) // Only move SL up
         {
            if(trade.PositionModify(positionTicket, newSL, positionTP))
            {
               PrintFormat("%s TRAILING_SL_UPDATED (BUY): oldSL=%.5f newSL=%.5f currentPrice=%.5f",
                          ts(TimeCurrent()), positionSL, newSL, currentPrice);
            }
         }
      }
   }
   else if(posType == POSITION_TYPE_SELL)
   {
      // Check if price has moved past minimum improvement level
      if(!trailingStopActivated)
      {
         if(currentPrice <= positionOpenPrice - minImprovement)
         {
            trailingStopActivated = true;
            PrintFormat("%s TRAILING_STOP_ACTIVATED (SELL): price=%.5f openPrice=%.5f minImprovement=%.5f",
                       ts(TimeCurrent()), currentPrice, positionOpenPrice, minImprovement);
         }
      }
      
      // If trailing stop is activated, adjust SL
      if(trailingStopActivated)
      {
         double newSL = currentPrice + trailingDistance;
         if(newSL < positionSL - PointSize() * MIN_SL_MOVEMENT_POINTS || positionSL == 0.0) // Only move SL down
         {
            if(trade.PositionModify(positionTicket, newSL, positionTP))
            {
               PrintFormat("%s TRAILING_SL_UPDATED (SELL): oldSL=%.5f newSL=%.5f currentPrice=%.5f",
                          ts(TimeCurrent()), positionSL, newSL, currentPrice);
            }
         }
      }
   }
}

void OnTick()
{
   // Manage trailing stop on every tick
   ManageTrailingStop();
   
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, PERIOD_CURRENT, 0, 3, rates) < 3) return;
   datetime closed = rates[1].time;
   if(closed == lastProcessedBar) return;
   lastProcessedBar = closed;

   if(macdHandle == INVALID_HANDLE) CreateHandles();

   double mainBuf[];
   double sigBuf[];
   ArraySetAsSeries(mainBuf, true);
   ArraySetAsSeries(sigBuf, true);
   
   int gotMain = CopyBuffer(macdHandle, 0, 0, 3, mainBuf);
   int gotSig  = CopyBuffer(macdHandle, 1, 0, 3, sigBuf);
   if(gotMain < 3 || gotSig < 3)
   {
      PrintFormat("%s MACD no data", ts(closed));
      return;
   }

   double main_now  = mainBuf[1];
   double main_prev = mainBuf[2];
   double sig_now   = sigBuf[1];
   double sig_prev  = sigBuf[2];

   double absMain_now  = MathAbs(main_now);
   double absMain_prev = MathAbs(main_prev);
   double absSig_now   = MathAbs(sig_now);
   double absSig_prev  = MathAbs(sig_prev);

   double hist_now  = absMain_now - absSig_now;
   double hist_prev = absMain_prev - absSig_prev;

   double atr = 0.0;
   if(atrHandle != INVALID_HANDLE)
   {
      double a[];
      ArraySetAsSeries(a, true);
      if(CopyBuffer(atrHandle, 0, 0, 2, a) > 0) atr = a[1];
   }

   double rsi = 50.0;
   if(rsiHandle != INVALID_HANDLE)
   {
      double r[];
      ArraySetAsSeries(r, true);
      if(CopyBuffer(rsiHandle, 0, 0, 2, r) > 0) rsi = r[1];
   }

   double safeEps = absSig_now * 0.001;
   if(safeEps < 1e-10) safeEps = 1e-10;
   
   double gapReq = absSig_now * GapPct;
   if(gapReq < safeEps) gapReq = safeEps;

   PrintFormat("%s BAR=%s main_now=%.6f sig_now=%.6f main_prev=%.6f sig_prev=%.6f hist_n=%.8f hist_p=%.8f rsi=%.1f",
               ts(TimeCurrent()), ts(closed), main_now, sig_now, main_prev, sig_prev, hist_now, hist_prev, rsi);

   bool signalEmerged = (hist_prev > safeEps && hist_now < -safeEps);
   bool signalReEntered = (hist_prev < -safeEps && hist_now > safeEps);

   if(signalReEntered && (armedBuy || armedSell))
   {
      PrintFormat("%s DISARM: signal re-entered main", ts(closed));
      armedBuy = false;
      armedSell = false;
      armedBuyID = 0;
      armedSellID = 0;
   }

   if(signalEmerged && ! armedBuy && ! armedSell)
   {
      currentArmCounter++;
      if(sig_now > 0.0)
      {
         armedSell = true;
         armedSellID = currentArmCounter;
         PrintFormat("%s ARM_SELL: sig>0 emerged arm=%d hist_p=%.8f hist_n=%.8f", ts(closed), armedSellID, hist_prev, hist_now);
      }
      else if(sig_now < 0.0)
      {
         armedBuy = true;
         armedBuyID = currentArmCounter;
         PrintFormat("%s ARM_BUY: sig<0 emerged arm=%d hist_p=%. 8f hist_n=%.8f", ts(closed), armedBuyID, hist_prev, hist_now);
      }
   }

   bool willBuy = false;
   bool willSell = false;
   int armToUse = 0;
   double entry = rates[1].close;
   double sl = 0.0;
   double tp = 0.0;

   if(armedBuy && hist_now < 0.0 && MathAbs(hist_now) >= gapReq)
   {
      PrintFormat("%s CHECK_BUY: hist=%.2e gapReq=%.2e rsi=%.1f", ts(closed), hist_now, gapReq, rsi);
      if(rsi >= RSI_Buy_Th)
      {
         willBuy = true;
         armToUse = armedBuyID;
         double slDist = (atr > 0.0) ? atr * ATR_Mult : PointSize() * 500.0;
         sl = entry - slDist;
         tp = entry + TP_Mult * slDist;
      }
      else
      {
         PrintFormat("%s BUY_RSI_BLOCK: rsi=%.1f < %. 1f", ts(closed), rsi, RSI_Buy_Th);
      }
   }

   if(armedSell && hist_now < 0.0 && MathAbs(hist_now) >= gapReq)
   {
      PrintFormat("%s CHECK_SELL: hist=%.2e gapReq=%.2e rsi=%.1f", ts(closed), hist_now, gapReq, rsi);
      if(rsi <= RSI_Sell_Th)
      {
         willSell = true;
         armToUse = armedSellID;
         double slDist = (atr > 0.0) ? atr * ATR_Mult : PointSize() * 500.0;
         sl = entry + slDist;
         tp = entry - TP_Mult * slDist;
      }
      else
      {
         PrintFormat("%s SELL_RSI_BLOCK: rsi=%.1f > %.1f", ts(closed), rsi, RSI_Sell_Th);
      }
   }

   if(willBuy || willSell)
   {
      bool blocked = false;
      if(UseGlobalGuard)
      {
         string gvName = GvNameLastOrder();
         if(GlobalVariableCheck(gvName))
         {
            if((int)GlobalVariableGet(gvName) == (int)closed) blocked = true;
         }
         if(armToUse != 0 && armToUse == lastFiredArmID) blocked = true;
      }

      if(blocked)
      {
         PrintFormat("%s BLOCKED: duplicate", ts(closed));
      }
      else
      {
         double lots = CalcLotsWithStepUp(entry, sl);

         if(lots <= 0.0)
         {
            PrintFormat("%s LOT_CALC_FAILED: entry=%.5f sl=%.5f", ts(closed), entry, sl);
         }
         else
         {
            bool sent = PlaceMarketOrder(willBuy, lots, sl, tp, StringFormat("WC arm=%d dbl=%d", armToUse, consecutiveLosses));
            if(sent)
            {
               PrintFormat("%s ORDER: %s arm=%d lots=%.2f entry=%.5f sl=%.5f tp=%.5f consLosses=%d", 
                           ts(closed), willBuy ? "BUY" : "SELL", armToUse, lots, entry, sl, tp, consecutiveLosses);
               lastFiredArmID = armToUse;
               GlobalVariableSet(GvNameLastOrder(), (double)closed);
               GlobalVariableSet(GvNameLastFiredArm(), (double)lastFiredArmID);
               
               // Store position information for trailing stop
               trailingStopActivated = false;
               positionOpenPrice = entry;
               positionIsBuy = willBuy;

               if(willBuy)
               {
                  armedBuy = false;
                  armedBuyID = 0;
               }
               if(willSell)
               {
                  armedSell = false;
                  armedSellID = 0;
               }
            }
         }
      }
   }
}
//+------------------------------------------------------------------+
