//+------------------------------------------------------------------+
//| Engulfing Candle Retrace EA - Multi-candle Retrace Logic         |
//| Trades at latest completed bar in Strategy Tester                |
//| Engulfing candle = range >= ATRMultiplier * ATR (no prev checks) |
//| Includes debug output for lot sizing calculation                 |
//| Doji threshold is user-definable and used for retrace filtering  |
//+------------------------------------------------------------------+
#property copyright "KWCASTLE"
#property link      "https://github.com/KWCASTLE"
#property version   "1.74"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//--- Inputs
enum TimeframeDrop { M1, M5, M15, M30, H1, H4, D1, W1, MN1 };
input TimeframeDrop inpTimeframe = M1;
input double inpPercentRisk         = 1.0;
input bool   inpFridayTrading       = false;
input double inpLossMultiplier1     = 1.0;
input double inpLossMultiplier2     = 1.0;
input double inpLossMultiplier3     = 1.0;
input bool   inpStepUpResetOn4th    = true;
input double inpSlippage            = 3;
input int    inpMagicNum            = 12345;
input double inpRetraceLevel        = 0.618;
input double inpTP_SL_Ratio         = 3.0;
input int    inpATRPeriod           = 10;
input double inpATRMultiplier       = 2.0;
input double inpDojiThreshold       = 0.00001; // Open/Close difference threshold for doji ignore

//--- Loss tracking
int lossCount = 0;
bool paused = false;

//--- Working variables
double PercentRisk;
ENUM_TIMEFRAMES Timeframe;
bool FridayTrading;
double LossMultiplier1;
double LossMultiplier2;
double LossMultiplier3;
bool StepUpResetOn4th;
int Slippage;
int MagicNum;
double RetraceLevel;
double TP_SL_Ratio;
int ATRPeriod;
double ATRMultiplier;
double DojiThreshold;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   PercentRisk = inpPercentRisk;
   ATRPeriod = inpATRPeriod;
   ATRMultiplier = inpATRMultiplier;
   DojiThreshold = inpDojiThreshold;
   switch(inpTimeframe)
   {
      case M1:   Timeframe = PERIOD_M1;   break;
      case M5:   Timeframe = PERIOD_M5;   break;
      case M15:  Timeframe = PERIOD_M15;  break;
      case M30:  Timeframe = PERIOD_M30;  break;
      case H1:   Timeframe = PERIOD_H1;   break;
      case H4:   Timeframe = PERIOD_H4;   break;
      case D1:   Timeframe = PERIOD_D1;   break;
      case W1:   Timeframe = PERIOD_W1;   break;
      case MN1:  Timeframe = PERIOD_MN1;  break;
      default:   Timeframe = PERIOD_M1;   break;
   }
   FridayTrading = inpFridayTrading;
   LossMultiplier1 = inpLossMultiplier1;
   LossMultiplier2 = inpLossMultiplier2;
   LossMultiplier3 = inpLossMultiplier3;
   StepUpResetOn4th = inpStepUpResetOn4th;
   Slippage = (int)inpSlippage;
   MagicNum = inpMagicNum;
   RetraceLevel = inpRetraceLevel;
   TP_SL_Ratio = inpTP_SL_Ratio;
   // Create file with headers if not exists
   int fileHandle = FileOpen("EngulfingDebug.csv", FILE_CSV|FILE_WRITE|FILE_READ|FILE_ANSI);
   if(fileHandle != INVALID_HANDLE && FileSize(fileHandle) == 0)
   {
      FileWrite(fileHandle, "BarTime,Type,Open,Close,High,Low,EngulfRange,ATR,ATRMultiplier,RetraceResult,EntryPrice,SL,TP,SLDist,TPDist,TP_SL_Ratio,LotSize,LotDebug,TradeResult");
   }
   if(fileHandle != INVALID_HANDLE) FileClose(fileHandle);
   Print("DEBUG: EngulfingRetraceEA initialized.");
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   Print("DEBUG: EngulfingRetraceEA deinitialized.");
}

//+------------------------------------------------------------------+
//| Calculate ATR (Average True Range) of last N candles             |
//+------------------------------------------------------------------+
double CalcATR(const MqlRates &price[], int period, int idx)
{
   double sum = 0.0;
   int count = 0;
   for(int i=idx; i>idx-period && i>=0; i--)
   {
      double range = MathAbs(price[i].high - price[i].low);
      sum += range;
      count++;
   }
   double atr = (count > 0) ? (sum / count) : 0.0;
   return atr;
}

//+------------------------------------------------------------------+
//| Calculate Lot Size Based On Risk % and Symbol pip value          |
//+------------------------------------------------------------------+
double LotSizeByRisk(double entryPrice, double stopLossPrice, double percentRisk, string &debugOut)
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * percentRisk / 100.0;

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double pip_size = 0.0001;
   double pip_value_per_lot = 0.0;

   debugOut = StringFormat("Balance: %.2f, RiskAmount: %.2f, Digits: %d, ", balance, riskAmount, digits);

   if(StringFind(_Symbol, "JPY") > -1)
   {
      pip_size = 0.01;
      pip_value_per_lot = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      debugOut += StringFormat("JPY symbol, pip_size: %.5f, pip_value_per_lot: %.5f, ", pip_size, pip_value_per_lot);
   }
   else
   {
      pip_size = (digits == 5) ? 0.00010 : 0.0001;
      double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      if(digits == 5)
         pip_value_per_lot = tick_value * 10.0;
      else
         pip_value_per_lot = tick_value;
      debugOut += StringFormat("Non-JPY, tick_value: %.5f, pip_size: %.5f, pip_value_per_lot: %.5f, ", tick_value, pip_size, pip_value_per_lot);
   }

   double sl_distance = MathAbs(entryPrice - stopLossPrice);
   double sl_pips = sl_distance / pip_size;
   double lot_size = 0.0;

   debugOut += StringFormat("EntryPrice: %.5f, StopLossPrice: %.5f, SL_Distance: %.5f, SL_Pips: %.2f, ", entryPrice, stopLossPrice, sl_distance, sl_pips);

   if(sl_pips > 0.0 && pip_value_per_lot > 0.0)
      lot_size = riskAmount / (sl_pips * pip_value_per_lot);
   debugOut += StringFormat("LotSize: %.5f", lot_size);

   return lot_size;
}

//+------------------------------------------------------------------+
//| MAIN TRADING LOGIC - Only trade at latest completed bar          |
//| Executes trades properly in Strategy Tester                      |
//+------------------------------------------------------------------+
void OnTick()
{
   if(paused) { return; }
   if(!FridayTrading && DayOfWeek() == 5) { return; }

   // Only check the LAST completed bar (index 1)
   MqlRates price[];
   int barsToCheck = MathMax(ATRPeriod + 5, 20);
   int copied = CopyRates(_Symbol, Timeframe, 0, barsToCheck, price);
   if(copied < ATRPeriod + 2) { return; }

   int engulfIdx = 1; // The last completed bar
   int prevIdx = engulfIdx + 1;
   double atr = CalcATR(price, ATRPeriod, engulfIdx);
   double engulfRange = MathAbs(price[engulfIdx].high - price[engulfIdx].low);

   // ATR multiplier check
   if(engulfRange < ATRMultiplier * atr) return;

   // Candle color for type
   string setupType = "";
   if(price[engulfIdx].open < price[engulfIdx].close) setupType = "Bull";
   else if(price[engulfIdx].open > price[engulfIdx].close) setupType = "Bear";
   else setupType = "Doji";
   if(setupType == "Doji") return;

   // Retrace logic - check only previous bar
   bool retraceOK = true;
   string retraceResult = "";
   int retraceStart = engulfIdx + 1;
   int retraceEnd = engulfIdx + 1;

   for(int i = retraceStart; i >= retraceEnd && i < copied; i--) // Only one bar
   {
      double retraceBody = MathAbs(price[i].close - price[i].open);
      bool isDoji = (retraceBody <= DojiThreshold);

      if(isDoji) {
         retraceResult += StringFormat("Retrace[%d] doji|", i);
         continue;
      }

      if(setupType == "Bull")
      {
         if(price[i].low <= price[engulfIdx].low)
         {
            retraceOK = false;
            retraceResult += StringFormat("Retrace[%d] brokeLow|", i);
            break;
         }
         if(price[i].high >= price[engulfIdx].close)
         {
            retraceOK = false;
            retraceResult += StringFormat("Retrace[%d] brokeHigh|", i);
            break;
         }
         if(price[i].close > price[i].open)
         {
            retraceOK = false;
            retraceResult += StringFormat("Retrace[%d] sameDirection|", i);
            break;
         }
      }
      else if(setupType == "Bear")
      {
         if(price[i].high >= price[engulfIdx].high)
         {
            retraceOK = false;
            retraceResult += StringFormat("Retrace[%d] brokeHigh|", i);
            break;
         }
         if(price[i].low <= price[engulfIdx].close)
         {
            retraceOK = false;
            retraceResult += StringFormat("Retrace[%d] brokeLow|", i);
            break;
         }
         if(price[i].close < price[i].open)
         {
            retraceOK = false;
            retraceResult += StringFormat("Retrace[%d] sameDirection|", i);
            break;
         }
      }
      retraceResult += StringFormat("Retrace[%d] OK|", i);
   }

   if(!retraceOK) return;

   double SL=0, TP=0, entryPrice=0;

   if(setupType == "Bull")
   {
      SL = price[engulfIdx].low;
      entryPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK); // Market price for buy
      TP = entryPrice + engulfRange*TP_SL_Ratio;
   }
   else if(setupType == "Bear")
   {
      SL = price[engulfIdx].high;
      entryPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID); // Market price for sell
      TP = entryPrice - engulfRange*TP_SL_Ratio;
   }

   double slDist = MathAbs(entryPrice-SL);
   double tpDist = MathAbs(TP-entryPrice);

   double lotSize = 0.0;
   string lotDebug = "";

   lotSize = LotSizeByRisk(entryPrice, SL, PercentRisk, lotDebug);

   // TP/SL ratio check
   if(tpDist/slDist < TP_SL_Ratio) return;

   // --- Trade Execution ---
   string tradeResult = "";
   bool executed = false;
   if(lotSize > 0.0)
   {
      if(setupType == "Bull")
      {
         executed = trade.Buy(lotSize, _Symbol, 0, SL, TP, "Engulfing Bull");
         if(executed)
            tradeResult = "BUY EXECUTED";
         else
            tradeResult = "BUY FAILED: " + (string)trade.ResultRetcode();
      }
      else if(setupType == "Bear")
      {
         executed = trade.Sell(lotSize, _Symbol, 0, SL, TP, "Engulfing Bear");
         if(executed)
            tradeResult = "SELL EXECUTED";
         else
            tradeResult = "SELL FAILED: " + (string)trade.ResultRetcode();
      }
   }
   else
   {
      tradeResult = "Lot size zero: No trade.";
   }

   // Write debug info for attempted setup
   int fileHandle = FileOpen("EngulfingDebug.csv", FILE_CSV|FILE_WRITE|FILE_READ|FILE_ANSI);
   if(fileHandle != INVALID_HANDLE) {
      FileSeek(fileHandle, 0, SEEK_END);
      FileWrite(fileHandle,
         TimeToString(price[engulfIdx].time, TIME_DATE|TIME_MINUTES),
         setupType,
         price[engulfIdx].open, price[engulfIdx].close, price[engulfIdx].high, price[engulfIdx].low,
         engulfRange, atr, ATRMultiplier,
         retraceResult, entryPrice, SL, TP, slDist, tpDist, tpDist/slDist, lotSize, lotDebug, tradeResult
      );
      FileClose(fileHandle);
   }
}

//+------------------------------------------------------------------+
//| Trade event handler: update lossCount, step up, reset, pause     |
//+------------------------------------------------------------------+
void OnTrade()
{
   datetime from = TimeCurrent() - 86400;
   datetime to = TimeCurrent();
   HistorySelect(from, to);
   double profit = 0;
   for(int i=HistoryDealsTotal()-1; i>=0; i--)
   {
      ulong deal_ticket = HistoryDealGetTicket(i);

      long deal_magic = HistoryDealGetInteger(deal_ticket, DEAL_MAGIC);
      double deal_profit = HistoryDealGetDouble(deal_ticket, DEAL_PROFIT);

      if(deal_magic == MagicNum)
      {
         profit = deal_profit;
         break;
      }
   }
   if(profit > 0)
   {
      lossCount = 0;
      paused = false;
      Print("DEBUG: Trade won. Loss count reset. EA active.");
   }
   else if(profit < 0)
   {
      lossCount++;
      Print("DEBUG: Trade lost. Loss count = ", lossCount);
      if(lossCount >= 4 && StepUpResetOn4th)
      {
         lossCount = 1;
         Print("DEBUG: Loss count reset due to 4th loss.");
      }
   }
}

//+------------------------------------------------------------------+
//| Day of week helper                                               |
//+------------------------------------------------------------------+
int DayOfWeek()
{
   MqlDateTime str;
   TimeToStruct(TimeCurrent(), str);
   return str.day_of_week;
}