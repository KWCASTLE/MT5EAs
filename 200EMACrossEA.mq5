//+------------------------------------------------------------------+
//| 200EMACrossEA: Mean bar-size + 200EMA cross strategy              |
//| - Candidate: strong (mean-sized) candle that opens & closes      |
//|   across the 200 EMA (open below & close above => buy signal;    |
//|   open above & close below => sell signal).                      |
//| - Entry: market order placed on the next candle (EA executes at  |
//|   market when the signal has just formed).                        |
//| - No broker stop-loss (SL) is placed. EA relies on an internal   |
//|   rule: close the position when a subsequent candle CLOSES back  |
//|   across the current 200 EMA.                                     |
//| - Backstop: on the OPEN of each candle the EA checks the open    |
//|   vs the most-recent 200 EMA; if it has already crossed back,    |
//|   the EA closes the position immediately.                         |
//| - The 200 EMA is recalculated on each new bar and used as the    |
//|   numeric SL reference (for risk calculation and exits only).     |
//| - Profit target = TakeProfitMultiple * (distance between entry   |
//|   and EMA at signal bar).                                         |
//| - Opposite-trade handling: EMAOverride enforced (same behavior   |
//|   as your prior EA).                                              |
//| - Risk per trade: fixed percent of free margin (no step-up).     |
//+------------------------------------------------------------------+
#property strict
#include <Trade\Trade.mqh>
CTrade trade;

// --------------------------- INPUTS -------------------------------
enum TimeframeDrop { M1=0, M5, M15, M30, H1, H4, D1, W1, MN1 };
input TimeframeDrop inpTimeframe = H4;        // EA timeframe

//debug/testing fixed lot (kept as variable in code)
// input double FixedLotForTesting = 0.0;     // uncomment to expose as input
double FixedLotForTesting = 0.0;             // set >0 in code to force fixed lots for debugging

input double RiskPercentPerTrade = 1.0;      // risk % of free margin per trade
input int    EngulfingOpenToleranceTicks = 2;
input double TakeProfitMultiple = 3.0;       // TP = multiplier * SL distance

// Mean candle (bar-size) filter (mean only)
input int    MeanBarSizePeriod = 14;         // lookback to compute mean bar range
input double MeanBarSizeMultiplier = 1.0;    // require thisBarRange >= multiplier * mean(range)

// EMA periods (we use only 200 EMA for crossing, keep others for trend check)
const int EMA_Fast_Period = 34;
const int EMA_Mid_Period  = 55;
const int EMA_Slow_Period = 200;             // 200 EMA used as crossing reference

// Trailing/backstop options
input bool  UseBarByBarTrailing = false;     // optional: move internal SL to previous closed bar extreme
input double TrailingMinMovePoints = 0.0;    // min improvement (points) before internal trailing

// Misc
input bool EnableDebugLogging = false;       // optional CSV debug (not implemented here)
string DebugFileName = "200EMACrossDebug.csv";

// --------------------------- GLOBALS -------------------------------
ENUM_TIMEFRAMES Timeframe = PERIOD_H4;
datetime lastProcessedBarTime = 0;
datetime lastTradedBarTime = 0;

int maxBuf = 500;

// --------------------------- HELPERS -------------------------------
// Map timeframe selection to ENUM_TIMEFRAMES
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

// Simple in-place EMA smoothing on an array of closes (arr[0] newest).
void SimpleEMAOnArray(double &arr[], int len, int period)
{
   if(period <= 1 || len <= 1) return;
   double alpha = 2.0/(period+1.0);
   for(int i=len-2; i>=0; i--)
      arr[i] = alpha*arr[i] + (1.0-alpha)*arr[i+1];
}

double CalcLotsByRisk(double entry, double stopLoss, double riskPercent)
{
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double minLot    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(tickSize <= 0 || tickValue <= 0 || lotStep <= 0) return 0.0;

   double riskMoney = (riskPercent/100.0) * freeMargin;
   double slTicks = MathAbs(entry - stopLoss) / tickSize;
   if(slTicks < 0.5) return 0.0;

   double lots = riskMoney / (slTicks * tickValue);
   lots = MathFloor(lots/lotStep) * lotStep;
   if(lots < minLot) lots = minLot;
   if(lots > maxLot) lots = maxLot;
   return lots;
}

// Engulfing detection helpers
bool IsBullEngulf(const MqlRates &curr, const MqlRates &prev, double tol)
{
   return (curr.open < curr.close) && (prev.open > prev.close)
      && (MathAbs(curr.close - curr.open) > MathAbs(prev.close - prev.open))
      && (curr.open <= prev.close + tol);
}
bool IsBearEngulf(const MqlRates &curr, const MqlRates &prev, double tol)
{
   return (curr.open > curr.close) && (prev.open < prev.close)
      && (MathAbs(curr.close - curr.open) > MathAbs(prev.close - prev.open))
      && (curr.open >= prev.close - tol);
}

// EMAOverride opposite-trade handling (enforced)
bool HandleOppositeTradeByEMA(double eFast, double eMid, double eSlow, bool bullSignal, bool bearSignal, string &reason)
{
   if(!PositionSelect(_Symbol)) return true;
   long posType = PositionGetInteger(POSITION_TYPE);
   bool isSame = (bullSignal && posType == POSITION_TYPE_BUY) || (bearSignal && posType == POSITION_TYPE_SELL);
   if(isSame) return true;

   // Uptrend
   if(eFast > eMid && eMid > eSlow)
   {
      if(bearSignal) { reason = "EMAOverride: Uptrend - sell bypassed"; return false; }
      if(posType == POSITION_TYPE_SELL && bullSignal) { ulong t=PositionGetInteger(POSITION_TICKET); trade.PositionClose(t); return true; }
   }
   // Downtrend
   else if(eSlow > eMid && eMid > eFast)
   {
      if(bullSignal) { reason = "EMAOverride: Downtrend - buy bypassed"; return false; }
      if(posType == POSITION_TYPE_BUY && bearSignal) { ulong t=PositionGetInteger(POSITION_TICKET); trade.PositionClose(t); return true; }
   }
   else
   {
      reason = "EMAOverride: No clear EMA order - bypass opposite";
      return false;
   }
   return true;
}

// Update trailing (optional) - moves SL internally toward profit using last closed bar extreme
void UpdateTrailingStop(const MqlRates &lastClosedBar)
{
   // This EA uses internal exit by EMA re-cross; this function is optional as a backstop/trailer.
   if(!PositionSelect(_Symbol)) return;
   long posType = PositionGetInteger(POSITION_TYPE);
   double currSL_internal = 0.0; // we don't push broker SL; this variable for possible bookkeeping if needed
   // Implementation left minimal - the EA relies on EMA recross to close positions.
}

// --------------------------- LIFECYCLE -------------------------------
int OnInit()
{
   Timeframe = TimeframeFromDrop(inpTimeframe);
   lastProcessedBarTime = 0;
   lastTradedBarTime = 0;
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   // nothing to release
}

// --------------------------- MAIN -------------------------------
void OnTick()
{
   // Copy recent bars for timeframe
   MqlRates price[];
   int want = MathMax(EMA_Slow_Period + 50, MeanBarSizePeriod + 20);
   int bars = CopyRates(_Symbol, Timeframe, 0, MathMin(want, maxBuf), price);
   if(bars < MathMax(EMA_Slow_Period, MeanBarSizePeriod) + 2) return;

   // Build EMA arrays (based on close)
   double emaFast[500], emaMid[500], emaSlow[500];
   int used = MathMin(bars, 500);
   for(int k=0; k<used; k++) { emaFast[k] = price[k].close; emaMid[k] = price[k].close; emaSlow[k] = price[k].close; }
   SimpleEMAOnArray(emaFast, used, EMA_Fast_Period);
   SimpleEMAOnArray(emaMid, used, EMA_Mid_Period);
   SimpleEMAOnArray(emaSlow, used, EMA_Slow_Period); // emaSlow[1] is EMA at last closed bar

   // --- BACKSTOP on NEW BAR OPEN ---
   // Use last-closed-bar EMA (emaSlow[1]) as current EMA reference; check current open price (price[0].open)
   if(used > 1 && PositionSelect(_Symbol))
   {
      long posType = PositionGetInteger(POSITION_TYPE);
      double lastClosedEMA = emaSlow[1];
      double currOpen = price[0].open;
      // For buy: if the new candle opened at or below the current EMA -> it has already crossed back -> close
      if(posType == POSITION_TYPE_BUY && currOpen <= lastClosedEMA)
      {
         ulong ticket = PositionGetInteger(POSITION_TICKET);
         trade.PositionClose(ticket);
      }
      // For sell: if the new candle opened at or above the current EMA -> close
      else if(posType == POSITION_TYPE_SELL && currOpen >= lastClosedEMA)
      {
         ulong ticket = PositionGetInteger(POSITION_TICKET);
         trade.PositionClose(ticket);
      }
   }

   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double tol = EngulfingOpenToleranceTicks * tickSize;

   // Loop over newly closed bars (newest closed is index 1, but we iterate to pick up unprocessed ones)
   for(int i = used - 2; i >= 1; i--)
   {
      datetime barTime = price[i].time;
      // skip bars still forming or already processed
      if(barTime > TimeCurrent() - PeriodSeconds(Timeframe)) continue;
      if(barTime <= lastProcessedBarTime) continue;

      // 1) mean-size filter
      bool barSizePass = true;
      if(MeanBarSizeMultiplier > 0.0 && (i + MeanBarSizePeriod) < used - 1)
      {
         double sum = 0.0;
         for(int j=0; j<MeanBarSizePeriod; j++)
            sum += MathAbs(price[i+1+j].high - price[i+1+j].low);
         double meanRange = sum / MeanBarSizePeriod;
         double thisRange = price[i].high - price[i].low;
         barSizePass = (thisRange >= MeanBarSizeMultiplier * meanRange);
      }

      // 2) 200EMA crossing qualifier (open/close across 200EMA)
      double ema200 = emaSlow[i]; // EMA at this closed bar
      bool bullCross = (price[i].open < ema200 && price[i].close > ema200);
      bool bearCross = (price[i].open > ema200 && price[i].close < ema200);

      // Manage existing open positions first: if this closed bar crosses back across the EMA, close position
      if(PositionSelect(_Symbol))
      {
         long posType = PositionGetInteger(POSITION_TYPE);
         // For buy: if this bar closed below EMA -> close
         if(posType == POSITION_TYPE_BUY && price[i].close < ema200)
         {
            ulong t = PositionGetInteger(POSITION_TICKET);
            trade.PositionClose(t);
         }
         // For sell: if this bar closed above EMA -> close
         else if(posType == POSITION_TYPE_SELL && price[i].close > ema200)
         {
            ulong t = PositionGetInteger(POSITION_TICKET);
            trade.PositionClose(t);
         }
      }

      // If candidate qualifies, attempt to open trade on market (EA executes near next candle open)
      if(barSizePass && (bullCross || bearCross))
      {
         // Use the signal-bar EMA (ema200) as the numeric SL reference for risk calculation.
         // We DO NOT place a broker SL (pass 0 to trade.Buy/Sell) — EA manages exits by EMA re-cross.
         double entryEstimate = price[i-1].open; // estimate of next bar open
         double SL_ref = ema200;
         double slDist = 0.0;
         if(bullCross) slDist = entryEstimate - SL_ref;
         else slDist = SL_ref - entryEstimate;

         if(slDist > 0.0)
         {
            double lots = (FixedLotForTesting > 0.0) ? FixedLotForTesting : CalcLotsByRisk(entryEstimate, SL_ref, RiskPercentPerTrade);
            if(lots > 0.0 && lastTradedBarTime != barTime)
            {
               double TP = 0.0;
               if(bullCross) TP = entryEstimate + TakeProfitMultiple * slDist;
               else TP = entryEstimate - TakeProfitMultiple * slDist;

               // Opposite-trade handling by EMA trend
               double eFast = emaFast[i], eMid = emaMid[i], eSlow = emaSlow[i];
               string oppReason = "";
               bool allowTrade = HandleOppositeTradeByEMA(eFast, eMid, eSlow, bullCross, bearCross, oppReason);

               if(allowTrade)
               {
                  string comment = StringFormat("200EMACross|%s|EBody=%.5f", bullCross ? "Bull" : "Bear", MathAbs(price[i].close - price[i].open));

                  // Place market order with NO broker SL (sl parameter = 0). EA will close on EMA re-cross.
                  bool executed = false;
                  if(bullCross) executed = trade.Buy(lots, _Symbol, 0.0, 0.0, TP, comment);
                  else executed = trade.Sell(lots, _Symbol, 0.0, 0.0, TP, comment);

                  if(executed)
                     lastTradedBarTime = barTime;
               }
            }
         } // end slDist > 0
      } // end candidate

      lastProcessedBarTime = barTime;
   } // end for

   // Optional: trailing/backstop using last closed bar extreme (not broker SL)
   if(UseBarByBarTrailing && used > 2)
   {
      UpdateTrailingStop(price[1]);
   }
}
//+------------------------------------------------------------------+