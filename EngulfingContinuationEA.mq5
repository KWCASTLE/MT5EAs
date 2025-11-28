//+------------------------------------------------------------------+
//| EngulfingContinuationEA                                          |
//| - Engulfing detection on closed bars                              |
//| - Mean-based bar-size filter (Mean Bar Size Multiplier)           |
//| - RSI filter for buys/sells                                       |
//| - EMA-based opposite-trade override (fixed)                       |
//| - Fixed EMA periods (34,55,200)                                   |
//| - Bar-by-bar trailing stop (moves only toward profit)             |
//| - No risk step-up on loss (constant RiskPercentPerTrade)          |
//| - Test date inputs commented out for future debugging             |
//| - FixedLotForTesting input commented-out but still functional     |
//+------------------------------------------------------------------+
#property strict
#include <Trade\Trade.mqh>
CTrade trade;

// --- Timeframe dropdown ---
enum TimeframeDrop { M1=0, M5, M15, M30, H1, H4, D1, W1, MN1 };
input TimeframeDrop inpTimeframe = H4;

// --- Trading / sizing ---
//input double FixedLotForTesting = 0.0; // Uncomment to enable fixed lots for testing
double FixedLotForTesting = 0.0;        // kept available in code (not exposed as input)
input double RiskPercentPerTrade = 1.0; // percent of free margin per trade

input int EngulfingOpenToleranceTicks = 2;
input double TakeProfitMultiple = 8.0;
// input datetime TestFromDate = D'2025.09.01 00:00'; // kept commented for future debug
// input datetime TestToDate   = D'2025.09.30 23:59'; // kept commented for future debug
// input bool UseTestDateRange = false;                // kept commented for future debug

// --- Bar Range Filter Inputs (mean only) ---
input int    BarRange_Mean_Period = 31;           // Period for mean of bar ranges
input double MeanBarSizeMultiplier  = 4.0;        // Engulfing bar must be >= multiplier * mean bar range

// --- Fixed EMA periods (not inputs) ---
const int EMA_Fast_Period = 49;
const int EMA_Mid_Period  = 55;
const int EMA_Slow_Period = 200;

// --- RSI filter inputs ---
input int RSI_Period = 49;
input double RSI_Buy_Threshold  = 45.0;   // allow buys only when RSI < this
input double RSI_Sell_Threshold = 55.0;   // allow sells only when RSI > this

// --- Opposite trade handling: EMA override enforced ---
enum _OppMode { EMAOverrideOnly = 0 };
const _OppMode OppositeTradeHandling = EMAOverrideOnly; // fixed

// --- runtime globals ---
ENUM_TIMEFRAMES Timeframe = PERIOD_H4;
datetime lastProcessedBarTime = 0;
datetime lastTradedBarTime = 0;

int rsiHandle = INVALID_HANDLE;
ulong lastClosedOrderTicket = 0;

// ----------------- helpers -----------------
ENUM_TIMEFRAMES TimeframeFromDrop(TimeframeDrop tf)
{
   switch(tf)
   {
      case M1:  return PERIOD_M1;
      case M5:  return PERIOD_M5;
      case M15: return PERIOD_M15;
      case M30: return PERIOD_M30;
      case H1:  return PERIOD_H1;
      case H4:  return PERIOD_H4;
      case D1:  return PERIOD_D1;
      case W1:  return PERIOD_W1;
      case MN1: return PERIOD_MN1;
      default:  return PERIOD_H4;
   }
}

// Engulfing detection (tolerance in price units)
bool IsSimpleBullishEngulf(const MqlRates &curr, const MqlRates &prev, double tol)
{
   return (curr.open < curr.close) && (prev.open > prev.close)
      && (MathAbs(curr.close - curr.open) > MathAbs(prev.close - prev.open))
      && (curr.open <= prev.close + tol);
}
bool IsSimpleBearishEngulf(const MqlRates &curr, const MqlRates &prev, double tol)
{
   return (curr.open > curr.close) && (prev.open < prev.close)
      && (MathAbs(curr.close - curr.open) > MathAbs(prev.close - prev.open))
      && (curr.open >= prev.close - tol);
}

// Simple in-place EMA on array of closes (arr[0] is most recent)
void SimpleEMAOnArray(double &arr[], int len, int period)
{
   if(period <= 1 || len <= 1) return;
   double alpha = 2.0 / (period + 1.0);
   for(int i = len-2; i >= 0; i--)
      arr[i] = alpha * arr[i] + (1.0 - alpha) * arr[i+1];
}

double CalcLotsByRisk(double entry, double stopLoss, double riskPercent)
{
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double minLot    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);

   double riskMoney = (riskPercent/100.0) * freeMargin;
   double slTicks = MathAbs(entry - stopLoss) / tickSize;
   if(slTicks < 0.5) return 0.0;

   double lots = riskMoney / (slTicks * tickValue);
   if(lotStep <= 0) return 0.0;
   lots = MathFloor(lots / lotStep) * lotStep;
   if(lots < minLot) lots = minLot;
   if(lots > maxLot) lots = maxLot;
   return lots;
}

// Update trailing SL to previous closed bar extreme (bar-by-bar trailing)
void UpdateTrailingStop(const MqlRates &lastClosedBar)
{
   if(!PositionSelect(_Symbol)) return;
   ulong ticket = PositionGetInteger(POSITION_TICKET);
   long type = PositionGetInteger(POSITION_TYPE);
   double currSL = PositionGetDouble(POSITION_SL);
   double newSL = currSL;
   if(type == POSITION_TYPE_BUY)
   {
      if(lastClosedBar.low > currSL + 1e-10)
         newSL = lastClosedBar.low;
   }
   else if(type == POSITION_TYPE_SELL)
   {
      if(lastClosedBar.high < currSL - 1e-10)
         newSL = lastClosedBar.high;
   }
   if(newSL != currSL)
      trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
}

// Check history orders for last closed update (keeps lastClosedOrderTicket)
void CheckTradeResults()
{
   int totalOrders = HistoryOrdersTotal();
   for(int i = totalOrders - 1; i >= 0; i--)
   {
      ulong ticket = HistoryOrderGetTicket(i);
      if(ticket == 0) continue;
      long type = HistoryOrderGetInteger(ticket, ORDER_TYPE);
      if(type != ORDER_TYPE_BUY && type != ORDER_TYPE_SELL) continue;
      long state = HistoryOrderGetInteger(ticket, ORDER_STATE);
      if(state != ORDER_STATE_FILLED) continue;
      if(ticket == lastClosedOrderTicket) break;
      lastClosedOrderTicket = ticket;
      break;
   }
}

// ----------------- lifecycle -----------------
int OnInit()
{
   Timeframe = TimeframeFromDrop(inpTimeframe);
   lastProcessedBarTime = 0;
   lastTradedBarTime = 0;
   lastClosedOrderTicket = 0;

   // create RSI handle for repeated use
   rsiHandle = iRSI(_Symbol, Timeframe, RSI_Period, PRICE_CLOSE);
   if(rsiHandle == INVALID_HANDLE)
      Print("Warning: iRSI handle creation failed. RSI filter will use neutral fallback.");

   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   if(rsiHandle != INVALID_HANDLE)
      IndicatorRelease(rsiHandle);
}

// ----------------- main -----------------
void OnTick()
{
   CheckTradeResults();

   // copy rates
   MqlRates price[];
   int bars = CopyRates(_Symbol, Timeframe, 0, MathMax(EMA_Slow_Period + 50, BarRange_Mean_Period + 20), price);
   if(bars < MathMax(EMA_Slow_Period, BarRange_Mean_Period) + 2) return;

   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double tolerance = EngulfingOpenToleranceTicks * tickSize;

   // --- EMA arrays (computed on close prices) ---
   double emaFast[500], emaMid[500], emaSlow[500];
   int maxcopy = MathMin(bars, 500);
   for(int k=0; k<maxcopy; k++) { emaFast[k] = price[k].close; emaMid[k] = price[k].close; emaSlow[k] = price[k].close; }
   SimpleEMAOnArray(emaFast, maxcopy, EMA_Fast_Period);
   SimpleEMAOnArray(emaMid,  maxcopy, EMA_Mid_Period);
   SimpleEMAOnArray(emaSlow, maxcopy, EMA_Slow_Period);

   // --- RSI copy ---
   double rsiBuf[500];
   for(int kk=0; kk<maxcopy; kk++) rsiBuf[kk] = 50.0; // fallback neutral
   if(rsiHandle != INVALID_HANDLE)
   {
      int copied = CopyBuffer(rsiHandle, 0, 0, maxcopy, rsiBuf);
      if(copied <= 0)
      {
         // leave neutral fallback
      }
   }

   // Main loop over closed bars (skip current open bar index 0)
   for(int i = bars - 2; i >= 1; i--)
   {
      datetime barTime = price[i].time;
      // skip current forming bar
      if(barTime > TimeCurrent() - PeriodSeconds(Timeframe)) continue;
      // process only new bars since lastProcessedBarTime
      if(barTime <= lastProcessedBarTime) continue;

      bool bull = IsSimpleBullishEngulf(price[i], price[i-1], tolerance);
      bool bear = IsSimpleBearishEngulf(price[i], price[i-1], tolerance);
      bool engulfing = bull || bear;
      double entry = price[i-1].open;
      double SL=0, TP=0, lots=0, slDist=0;
      string tradeResult = "NoEngulf";

      // --- mean bar-range filter (mean only) ---
      double barRange = price[i].high - price[i].low;
      double barRangeStat = 0.0;
      bool barRangePass = true;
      if(MeanBarSizeMultiplier > 0.0 && (i + BarRange_Mean_Period) < bars - 1)
      {
         double sum = 0.0;
         for(int j=0;j<BarRange_Mean_Period;j++) sum += MathAbs(price[i+1+j].high - price[i+1+j].low);
         barRangeStat = sum / BarRange_Mean_Period;
         barRangePass = (barRange >= MeanBarSizeMultiplier * barRangeStat);
      }

      // --- EMA values for this bar
      double eFast = emaFast[i];
      double eMid  = emaMid[i];
      double eSlow = emaSlow[i];

      // --- RSI value for this bar (i-th closed bar)
      double rsiVal = rsiBuf[i];

      // --- RSI filter ---
      bool rsiPass = true;
      if(bull && rsiVal >= RSI_Buy_Threshold) rsiPass = false;
      if(bear && rsiVal <= RSI_Sell_Threshold) rsiPass = false;

      // --- Opposite-trade EMA override behavior (enforced) ---
      bool allowTrade = true;
      string oppReason = "";
      double prevBody = 0.0, newBody = MathAbs(price[i].close - price[i].open);

      if(PositionSelect(_Symbol))
      {
         long posType = PositionGetInteger(POSITION_TYPE);
         string posComment = PositionGetString(POSITION_COMMENT);
         int eq = StringFind(posComment, "EBody=");
         if(eq >= 0) prevBody = StringToDouble(StringSubstr(posComment, eq+6));

         bool isSameDirection = (bull && posType == POSITION_TYPE_BUY) || (bear && posType == POSITION_TYPE_SELL);

         if(!isSameDirection)
         {
            if(eFast > eMid && eMid > eSlow)
            {
               // uptrend: bypass sells, close existing sells on buy signal
               if(posType == POSITION_TYPE_BUY && bear)
               {
                  allowTrade = false;
                  oppReason = "EMAOverride: Uptrend, sell trade bypassed";
               }
               else if(posType == POSITION_TYPE_SELL && bull)
               {
                  ulong posTicket = PositionGetInteger(POSITION_TICKET);
                  trade.PositionClose(posTicket);
               }
            }
            else if(eSlow > eMid && eMid > eFast)
            {
               // downtrend: bypass buys, close existing buys on sell signal
               if(posType == POSITION_TYPE_SELL && bull)
               {
                  allowTrade = false;
                  oppReason = "EMAOverride: Downtrend, buy trade bypassed";
               }
               else if(posType == POSITION_TYPE_BUY && bear)
               {
                  ulong posTicket = PositionGetInteger(POSITION_TICKET);
                  trade.PositionClose(posTicket);
               }
            }
            else
            {
               // No clear EMA order -> do not open opposite trades
               allowTrade = false;
               oppReason = "EMAOverride: No clear EMA order, treat as bypass";
            }
         }
      }

      // --- ENTRY ---
      if(engulfing && barRangePass && rsiPass && allowTrade && lastTradedBarTime != barTime)
      {
         string tradeComment = StringFormat("Simple%sEngulfMultiSL|EBody=%.5f", bull ? "Bull" : "Bear", newBody);
         if(bull)
         {
            SL = price[i].low;
            slDist = entry - SL;
            TP = entry + TakeProfitMultiple * slDist;
         }
         if(bear)
         {
            SL = price[i].high;
            slDist = SL - entry;
            TP = entry - TakeProfitMultiple * slDist;
         }

         if(FixedLotForTesting > 0.0) lots = FixedLotForTesting;
         else lots = CalcLotsByRisk(entry, SL, RiskPercentPerTrade);

         if(lots <= 0.0) tradeResult = "CalcLotsZero";
         else
         {
            if(bull)
            {
               tradeResult = "TradeAttemptBuy";
               bool executed = trade.Buy(lots, _Symbol, 0, SL, TP, tradeComment);
               tradeResult = executed ? "TradeExecutedBuy" : "TradeFailedBuy";
               if(executed) lastTradedBarTime = barTime;
            }
            if(bear)
            {
               tradeResult = "TradeAttemptSell";
               bool executed = trade.Sell(lots, _Symbol, 0, SL, TP, tradeComment);
               tradeResult = executed ? "TradeExecutedSell" : "TradeFailedSell";
               if(executed) lastTradedBarTime = barTime;
            }
         }
      }

      // advance processed marker
      lastProcessedBarTime = barTime;
   } // end for bars

   // trailing update using most recent closed bar price[1]
   if(bars > 2)
      UpdateTrailingStop(price[1]);
}