//+------------------------------------------------------------------+
//| WaveCrestEA v1.87 - ensure magnitude-based ordering comparisons  |
//| - Use MathAbs(...) for ordering / overshoot comparisons (magnitude)
//| - Use only sign of main & hist to decide buy vs sell (positive=>sell, negative=>buy)
//| - Make init snapshot symmetric for buy and sell emergences
//| - Keep predictor / residual / hist magnitude / RSI gating intact
//| - Treat non-positive internal eps_input as "use MinOrderingGap"
//| - Add temporary testing toggles: ForcePassOrderingGap, ForceMinLots
//+------------------------------------------------------------------+
#property copyright "WaveCrestEA"
#property version   "1.87"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\DealInfo.mqh>
CTrade trade;

// --------------------------- COMPAT DEFINES -------------------------
#ifndef FILE_READ
  #define FILE_READ   1
#endif
#ifndef FILE_WRITE
  #define FILE_WRITE  2
#endif
#ifndef FILE_BIN
  #define FILE_BIN    4
#endif
#ifndef FILE_CSV
  #define FILE_CSV    8
#endif
#ifndef FILE_ANSI
  #define FILE_ANSI   16
#endif
#ifndef FILE_COMMON
  #define FILE_COMMON 32
#endif
#ifndef FILE_APPEND
  #define FILE_APPEND 64
#endif
#ifndef SEEK_SET
  #define SEEK_SET    0
#endif
#ifndef SEEK_CUR
  #define SEEK_CUR    1
#endif
#ifndef SEEK_END
  #define SEEK_END    2
#endif
// --------------------------------------------------------------------

// --------------------------- PROTOTYPES ------------------------------
void OpenDebugFiles();
void CloseDebugFiles();
bool WriteToAllFiles(string csvRow, string rawRow);
bool WriteStructuredRowOneShot(string row);
bool WriteRawRowOneShot(string row);

bool RecreateMacdHandle();
bool EnsureMacdHandle();

void BatchProcessRange(datetime from_time, datetime to_time);
void WriteInitSnapshot();

double PointSize();
double ComputeEpsilon(double atr);
double NormalizeLots(double lots);

double CalcLotsByRisk(double entryPrice, double stopPrice, double riskPercent);
double CalcLotsForEntry(double entry, double stop);
bool PlaceOrder(bool isBuy, double lots, double sl, double tp, string comment);

int  OnInit();
void OnDeinit(const int reason);
void OnTimer();
void OnTick();
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result);

bool WaitForMacdMainAndSignal(int closedOffset, int needCount, int maxAttempts, int sleepMs);
string TimeStampOrNA(datetime t);
int GetBarShift(string symbol, ENUM_TIMEFRAMES timeframe, datetime time);
// --------------------------------------------------------------------

// --------------------------- INPUTS --------------------------------
input int    MACD_Fast   = 12;
input int    MACD_Slow   = 26;
input int    MACD_Signal = 9;
input int    ATR_Period  = 14;
input double ATR_Multiplier = 1.5;
input double TP_Multiplier  = 2.0;
input double RiskPercentPerTrade = 0.5;
input double FixedLotForTesting  = 0.0;
input double MinLot = 0.01;
input int    MaxDoublings = 5;
input double LossMultiplier = 2.0;
input int    RSI_Period = 14;
input double RSI_Buy_Threshold = 45.0;
input double RSI_Sell_Threshold = 55.0;
input double HistOvershootThreshold = 0.00001;
input int    MinBarsBetweenSignals = 3;
input int    Emergence_RequiredBars = 2;
input double Emergence_kResidual = 1.0;
input double MinHistAbsMult = 1.0;
input bool   PrintTradeInfo = true;
input int    MaxRetriesOnSend = 1;

input bool   UseCarryPrev = true;
input bool   DisablePredictor = false;
input double MinOrderingGap = 0.00005;
input bool   ForcePassOrderingGap = false;   // TEMP: bypass ordering gap for testing
input double ForceMinLots = 0.0;            // TEMP: if >0 and computed lots round to 0, use this for testing
input int    RoundingDigitsOverride = 0;
input bool   ForceIndicatorAppliedPriceClose = true;

input bool   UseTestDateRange = false;
input datetime TestFromDate = D'2025.08.01 00:00';
input datetime TestToDate   = D'2025.11.10 23:59';

// --------------------------- DEBUG FILE NAMES -----------------------
string DEBUG_FILENAME  = "wavecrest_debug_struct.csv";
string RAW_FILENAME    = "wavecrest_debug_raw.txt";

// --------------------------- GLOBALS --------------------------------
int macdHandle = INVALID_HANDLE;
int atrHandle  = INVALID_HANDLE;
int rsiHandle  = INVALID_HANDLE;

datetime lastProcessedBarTime = 0;
int barsSinceLastEntry = 9999;
int look_for = 0;
int consecutiveLosses = 0;

int fh_local_struct = INVALID_HANDLE;
int fh_local_raw    = INVALID_HANDLE;
int fh_common_struct = INVALID_HANDLE;
int fh_common_raw   = INVALID_HANDLE;

string CSV_HEADER = "timestamp,event,signal_prev,signal_now,hist_prev,hist_now,main_prev,main_now,predicted_hist,residual,normResidual,safeEps,eps,atr,rsi,allowEntry,isBuy,isSell,blockedByRSI,blockedByOvershoot,blockedByNoSL,blockedByLots,slDistance,lots,entry,sl,tp,notes\r\n";

bool snapshotPending = false;

datetime lastLoggedNowTime = 0;
double lastLoggedNow_main = 0.0;
double lastLoggedNow_signal = 0.0;
double lastLoggedNow_hist = 0.0;

// --------------------------- HELPERS --------------------------------
double PointSize() { return(SymbolInfoDouble(_Symbol, SYMBOL_POINT)); }

double ComputeEpsilon(double atr)
{
   if(atr > 0.0) return MathMax(HistOvershootThreshold, 0.01 * atr);
   return MathMax(HistOvershootThreshold, PointSize()*1.0);
}

double NormalizeLots(double lots)
{
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double min  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step <= 0.0) return(0.0);
   double n = MathFloor(lots/step) * step;
   if(n < min) n = min;
   if(n > max) n = max;
   return n;
}

string TimeStampOrNA(datetime t)
{
   if(t <= 0) return "NA";
   return TimeToString(t, TIME_DATE|TIME_SECONDS);
}

// --------------------------- SIZING / TRADING -----------------------
double CalcLotsByRisk(double entryPrice, double stopPrice, double riskPercent)
{
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(freeMargin <= 0.0) return 0.0;
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0.0 || tickValue <= 0.0) return 0.0;
   double riskMoney = (riskPercent/100.0) * freeMargin;
   double slTicks = MathAbs(entryPrice - stopPrice) / tickSize;
   if(slTicks < 0.5) return 0.0;
   double lots = riskMoney / (slTicks * tickValue);
   if(lots <= 0.0) return 0.0;
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0) return 0.0;
   lots = MathFloor(lots / step) * step;
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(lots < minLot) return 0.0;
   if(lots > maxLot) lots = maxLot;
   return lots;
}

double CalcLotsForEntry(double entry, double stop)
{
   if(FixedLotForTesting > 0.0) return NormalizeLots(FixedLotForTesting);
   int doublings = consecutiveLosses;
   if(doublings < 0) doublings = 0;
   if(doublings > MaxDoublings) doublings = MaxDoublings;
   double safeMultiplier = LossMultiplier;
   if(safeMultiplier < 1.0) safeMultiplier = 1.0;
   double multiplier = MathPow(safeMultiplier, doublings);
   double effectiveRisk = RiskPercentPerTrade * multiplier;
   double l = CalcLotsByRisk(entry, stop, effectiveRisk);
   if(l < MinLot) return 0.0;
   return l;
}

bool PlaceOrder(bool isBuy, double lots, double sl, double tp, string comment)
{
   bool ok = false;
   for(int attempt=0; attempt<=MaxRetriesOnSend; ++attempt)
   {
      if(isBuy) ok = trade.Buy(lots, _Symbol, 0.0, sl, tp, comment);
      else      ok = trade.Sell(lots, _Symbol, 0.0, sl, tp, comment);
      if(ok) return true;
      int err = GetLastError();
      PrintFormat("WaveCrestEA: Order send failed attempt=%d err=%d", attempt, err);
      Sleep(200);
   }
   return false;
}

// --------------------------- FILE HELPERS ---------------------------
void OpenDebugFiles()
{
   PrintFormat("WaveCrestEA DIAG: TERMINAL_DATA_PATH = %s", TerminalInfoString(TERMINAL_DATA_PATH));
   PrintFormat("WaveCrestEA DIAG: TERMINAL_COMMONDATA_PATH = %s", TerminalInfoString(TERMINAL_COMMONDATA_PATH));

   if(fh_local_struct == INVALID_HANDLE)
   {
      fh_local_struct = FileOpen(DEBUG_FILENAME, FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_APPEND);
      PrintFormat("WaveCrestEA DIAG: fh_local_struct=%d GetLastError=%d", fh_local_struct, GetLastError());
      if(fh_local_struct != INVALID_HANDLE)
      {
         ulong pos_ul = (ulong)FileTell(fh_local_struct);
         int pos = (int)pos_ul;
         if(pos == 0) FileWriteString(fh_local_struct, CSV_HEADER);
         FileFlush(fh_local_struct);
      }
   }

   if(fh_local_raw == INVALID_HANDLE)
   {
      fh_local_raw = FileOpen(RAW_FILENAME, FILE_WRITE | FILE_ANSI | FILE_APPEND);
      PrintFormat("WaveCrestEA DIAG: fh_local_raw=%d GetLastError=%d", fh_local_raw, GetLastError());
      if(fh_local_raw != INVALID_HANDLE) FileFlush(fh_local_raw);
   }

   if(fh_common_struct == INVALID_HANDLE)
   {
      fh_common_struct = FileOpen(DEBUG_FILENAME, FILE_COMMON | FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_APPEND);
      PrintFormat("WaveCrestEA DIAG: fh_common_struct=%d GetLastError=%d", fh_common_struct, GetLastError());
      if(fh_common_struct != INVALID_HANDLE)
      {
         ulong pos_ul = (ulong)FileTell(fh_common_struct);
         int pos = (int)pos_ul;
         if(pos == 0) FileWriteString(fh_common_struct, CSV_HEADER);
         FileFlush(fh_common_struct);
      }
   }

   if(fh_common_raw == INVALID_HANDLE)
   {
      fh_common_raw = FileOpen(RAW_FILENAME, FILE_COMMON | FILE_WRITE | FILE_ANSI | FILE_APPEND);
      PrintFormat("WaveCrestEA DIAG: fh_common_raw=%d GetLastError=%d", fh_common_raw, GetLastError());
      if(fh_common_raw != INVALID_HANDLE) FileFlush(fh_common_raw);
   }

   // init test write
   string ts = TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS);
   string testRaw = StringFormat("%s,INIT_TEST,WaveCrestEA init test\r\n", ts);
   if(fh_local_raw != INVALID_HANDLE) FileWriteString(fh_local_raw, testRaw);
   if(fh_common_raw != INVALID_HANDLE) FileWriteString(fh_common_raw, testRaw);
   if(fh_local_raw != INVALID_HANDLE) FileFlush(fh_local_raw);
   if(fh_common_raw != INVALID_HANDLE) FileFlush(fh_common_raw);

   string testCSV = StringFormat("\"%s\",\"%s\",\"%s\"\r\n", ts, "INIT_TEST", "init");
   if(fh_local_struct != INVALID_HANDLE) FileWriteString(fh_local_struct, testCSV);
   if(fh_common_struct != INVALID_HANDLE) FileWriteString(fh_common_struct, testCSV);
   if(fh_local_struct != INVALID_HANDLE) FileFlush(fh_local_struct);
   if(fh_common_struct != INVALID_HANDLE) FileFlush(fh_common_struct);
}

void CloseDebugFiles()
{
   if(fh_local_struct != INVALID_HANDLE) { FileClose(fh_local_struct); fh_local_struct = INVALID_HANDLE; }
   if(fh_local_raw    != INVALID_HANDLE) { FileClose(fh_local_raw);    fh_local_raw    = INVALID_HANDLE; }
   if(fh_common_struct!= INVALID_HANDLE) { FileClose(fh_common_struct);fh_common_struct= INVALID_HANDLE; }
   if(fh_common_raw   != INVALID_HANDLE) { FileClose(fh_common_raw);   fh_common_raw   = INVALID_HANDLE; }
}

bool WriteToAllFiles(string csvRow, string rawRow)
{
   bool ok = true;
   bool w;

   if(StringLen(csvRow) > 0)
   {
      if(fh_local_struct != INVALID_HANDLE) { w = (FileWriteString(fh_local_struct, csvRow) > 0); FileFlush(fh_local_struct); ok = ok && w; } else ok = ok && WriteStructuredRowOneShot(csvRow);
      if(fh_common_struct!= INVALID_HANDLE) { w = (FileWriteString(fh_common_struct, csvRow) > 0); FileFlush(fh_common_struct); ok = ok && w; } else ok = ok && WriteStructuredRowOneShot(csvRow);
   }

   if(StringLen(rawRow) > 0)
   {
      if(fh_local_raw != INVALID_HANDLE) { w = (FileWriteString(fh_local_raw, rawRow) > 0); FileFlush(fh_local_raw); ok = ok && w; } else ok = ok && WriteRawRowOneShot(rawRow);
      if(fh_common_raw!= INVALID_HANDLE) { w = (FileWriteString(fh_common_raw, rawRow) > 0); FileFlush(fh_common_raw); ok = ok && w; } else ok = ok && WriteRawRowOneShot(rawRow);
   }

   if(!ok) PrintFormat("WaveCrestEA DIAG: WriteToAllFiles some writes failed GetLastError=%d", GetLastError());
   return ok;
}

bool WriteStructuredRowOneShot(string row)
{
   int fh = FileOpen(DEBUG_FILENAME, FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_APPEND);
   if(fh == INVALID_HANDLE) return false;
   FileWriteString(fh, row);
   FileFlush(fh);
   FileClose(fh);
   return true;
}
bool WriteRawRowOneShot(string row)
{
   int fh = FileOpen(RAW_FILENAME, FILE_WRITE | FILE_ANSI | FILE_APPEND);
   if(fh == INVALID_HANDLE) return false;
   FileWriteString(fh, row);
   FileFlush(fh);
   FileClose(fh);
   return true;
}

// --------------------------- INDICATOR HELPERS ----------------------
bool RecreateMacdHandle()
{
   if(macdHandle != INVALID_HANDLE) IndicatorRelease(macdHandle);
   macdHandle = iMACD(_Symbol, PERIOD_CURRENT, MACD_Fast, MACD_Slow, MACD_Signal, PRICE_CLOSE);
   PrintFormat("WaveCrestEA DIAG: RecreateMacdHandle -> handle=%d GetLastError=%d", macdHandle, GetLastError());
   return (macdHandle != INVALID_HANDLE);
}
bool EnsureMacdHandle()
{
   if(macdHandle != INVALID_HANDLE) return true;
   return RecreateMacdHandle();
}

bool WaitForMacdMainAndSignal(int closedOffset, int needCount, int maxAttempts, int sleepMs)
{
   if(!EnsureMacdHandle()) return false;

   for(int attempt=0; attempt<maxAttempts; ++attempt)
   {
      double mainBuf[], sigBuf[];
      ArrayResize(mainBuf, needCount);
      ArrayResize(sigBuf, needCount);
      ResetLastError();
      int gotMain = CopyBuffer(macdHandle, 0, closedOffset, needCount, mainBuf);
      int gotSig  = CopyBuffer(macdHandle, 1, closedOffset, needCount, sigBuf);
      int err = GetLastError();
      PrintFormat("WaveCrestEA DIAG: WaitForMacdMainAndSignal attempt=%d gotMain=%d gotSig=%d GetLastError=%d", attempt, gotMain, gotSig, err);
      if(gotMain >= needCount && gotSig >= needCount) return true;
      if(attempt == 2 || attempt == 6)
      {
         if(RecreateMacdHandle()) Print("WaveCrestEA DIAG: WaitForMacdMainAndSignal: Recreated MACD handle attempt");
      }
      Sleep(sleepMs);
   }
   PrintFormat("WaveCrestEA DIAG: WaitForMacdMainAndSignal timed out after %d attempts", maxAttempts);
   return false;
}

// --------------------------- INIT SNAPSHOT --------------------------
void WriteInitSnapshot()
{
   if(!EnsureMacdHandle()) return;

   int closedOffset = 1;
   int needCount = 3;
   bool okbuff = WaitForMacdMainAndSignal(closedOffset, needCount, 10, 200);
   if(!okbuff) { Print("WaveCrestEA DIAG: WriteInitSnapshot: MACD unavailable"); return; }

   double mainBuf[3], sigBuf[3];
   int gotMain = CopyBuffer(macdHandle, 0, closedOffset, 3, mainBuf);
   int gotSig  = CopyBuffer(macdHandle, 1, closedOffset, 3, sigBuf);
   PrintFormat("WaveCrestEA DIAG: WriteInitSnapshot CopyBuffer gotMain=%d gotSig=%d", gotMain, gotSig);
   if(gotMain < 2 || gotSig < 2)
   {
      PrintFormat("WaveCrestEA DIAG: WriteInitSnapshot: insufficient indicator data gotMain=%d gotSig=%d", gotMain, gotSig);
      return;
   }

   double main_now   = mainBuf[0], main_prev   = mainBuf[1];
   double signal_now = sigBuf[0],  signal_prev = sigBuf[1];
   double hist_now   = main_now - signal_now;
   double hist_prev  = main_prev - signal_prev;

   double atr = 0.0;
   if(atrHandle != INVALID_HANDLE)
   {
      double atrB[]; int c = CopyBuffer(atrHandle, 0, closedOffset, 1, atrB); if(c>0) atr = atrB[0];
   }
   double eps = ComputeEpsilon(atr);
   double safeEps = MathMax(eps, PointSize()*1e-12);

   double eps_input = HistOvershootThreshold;
   int roundingDigits = 1;
   if(RoundingDigitsOverride > 0) roundingDigits = RoundingDigitsOverride;
   else if(eps_input > 0.0) roundingDigits = (int)MathMax(1.0, MathCeil(-MathLog10(eps_input)));

   double main_prev_r   = NormalizeDouble(main_prev, roundingDigits);
   double main_now_r    = NormalizeDouble(main_now, roundingDigits);
   double signal_prev_r = NormalizeDouble(signal_prev, roundingDigits);
   double signal_now_r  = NormalizeDouble(signal_now, roundingDigits);
   double hist_prev_r   = NormalizeDouble(main_prev_r - signal_prev_r, roundingDigits);
   double hist_now_r    = NormalizeDouble(main_now_r - signal_now_r, roundingDigits);

   double alpha = 2.0 / (MACD_Signal + 1.0);
   double predicted_hist_now = hist_prev + (1.0 - alpha) * (main_now - main_prev);
   double residual = hist_now - predicted_hist_now;
   double normResidual = safeEps > 0.0 ? (residual / safeEps) : 0.0;

   double rsi = 50.0;
   if(rsiHandle != INVALID_HANDLE)
   {
      double rsiB[]; int c = CopyBuffer(rsiHandle, 0, closedOffset, 1, rsiB); if(c>0) rsi = rsiB[0];
   }

   MqlRates rateArr[];
   int copied = CopyRates(_Symbol, PERIOD_CURRENT, closedOffset, 2, rateArr); // now + prev
   PrintFormat("WaveCrestEA DIAG: WriteInitSnapshot CopyRates copied=%d", copied);
   if(copied < 1) { Print("WaveCrestEA DIAG: WriteInitSnapshot insufficient rates"); return; }
   string now_ts  = TimeStampOrNA(copied >= 1 ? rateArr[0].time : 0);
   string prev_ts = TimeStampOrNA(copied >= 2 ? rateArr[1].time : 0);
   string ts = now_ts;

   // ordering gap uses magnitudes
   double orderingGap = MathAbs(MathAbs(signal_now_r) - MathAbs(main_now_r));
   int mainSignalSameSign = (main_now * signal_now) > 0.0 ? 1 : 0;
   int histLargeEnough  = (MathAbs(hist_now_r) >= (MinHistAbsMult * safeEps)) ? 1 : 0;

   // epsilon comparison: treat non-positive eps_input as "use MinOrderingGap"
   double eps_compare_init;
   if(eps_input <= 0.0) eps_compare_init = MinOrderingGap;
   else eps_compare_init = MathMax(MathAbs(eps_input), MinOrderingGap);
   int orderingGapLargeEnough_init = (ForcePassOrderingGap || (orderingGap > eps_compare_init)) ? 1 : 0;

   string macdCsv = StringFormat("\"%s\",\"MACD_DEBUG\",signal_prev=%.8g@%s,signal_now=%.8g@%s,hist_prev=%.8g@%s,hist_now=%.8g@%s,main_prev=%.8g@%s,main_now=%.8g@%s,predicted_hist=%.8g,residual=%.8g,normResidual=%.6g,safeEps=%.8g,eps=%.8g,atr=%.8g,rsi=%.8g\r\n",
                                ts,
                                signal_prev, prev_ts,
                                signal_now,  now_ts,
                                hist_prev,   prev_ts,
                                hist_now,    now_ts,
                                main_prev, prev_ts,
                                main_now,  now_ts,
                                predicted_hist_now, residual, normResidual, safeEps, eps, atr, rsi);
   string macdRaw = StringFormat("%s,MACD_DEBUG,signal_prev=%.8g@%s,signal_now=%.8g@%s,hist_prev=%.8g@%s,hist_now=%.8g@%s,main_prev=%.8g,main_now=%.8g,predicted_hist=%.8g,residual=%.8g,normResidual=%.6g,safeEps=%.8g,eps=%.8g,atr=%.8g,rsi=%.8g\n",
                                ts, signal_prev, prev_ts,
                                signal_now,  now_ts,
                                hist_prev,   prev_ts,
                                hist_now,    now_ts,
                                main_prev, main_now, predicted_hist_now, residual, normResidual, safeEps, eps, atr, rsi);

   if(PrintTradeInfo) Print("WaveCrestEA DIAG: WriteInitSnapshot: writing MACD_DEBUG");
   WriteToAllFiles(macdCsv, macdRaw);

   // Determine emergence for both sides purely by sign of main and hist (no zero-cross logging).
   int perBuy = 0;
   int perSell = 0;
   if(mainSignalSameSign && histLargeEnough)
   {
      // buy side: both negative and residual sufficiently negative (if predictor enabled)
      if(main_now < 0.0 && hist_now < 0.0)
      {
         if(DisablePredictor) perBuy = 1;
         else if(normResidual <= -Emergence_kResidual) perBuy = 1;
      }
      // sell side: both positive and residual sufficiently positive (if predictor enabled)
      if(main_now > 0.0 && hist_now > 0.0)
      {
         if(DisablePredictor) perSell = 1;
         else if(normResidual >= Emergence_kResidual) perSell = 1;
      }
   }

   string notes = StringFormat("init_snapshot rnd=%d gap=%.8g eps_input=%.8g eps_compare=%.8g orderingGapLargeEnough=%d", roundingDigits, orderingGap, eps_input, eps_compare_init, orderingGapLargeEnough_init);

   string decCsv = StringFormat("\"%s\",\"DECISION_SUMMARY\",main_prev=%.8g@%s,main_now=%.8g@%s,signal_prev=%.8g,signal_now=%.8g,mainSignalSameSign=%d,histLargeEnough=%d,perBuy=%d,perSell=%d,atr=%.8g,rsi=%.8g,rnd=%d,gap=%.8g,notes=\"%s\"\r\n",
                               ts, main_prev, prev_ts, main_now, now_ts,
                               signal_prev, signal_now, mainSignalSameSign, histLargeEnough, perBuy, perSell, atr, rsi, roundingDigits, orderingGap, notes);
   string decRaw = StringFormat("%s,DECISION_SUMMARY,mainSignalSameSign=%d,histLargeEnough=%d,perBuy=%d,perSell=%d,atr=%.8g,rsi=%.8g,rnd=%d,gap=%.8g,eps_input=%.8g,eps_compare=%.8g,orderingGapLargeEnough=%d\n",
                               ts, mainSignalSameSign, histLargeEnough, perBuy, perSell, atr, rsi, roundingDigits, orderingGap, eps_input, eps_compare_init, orderingGapLargeEnough_init);

   if(PrintTradeInfo) Print("WaveCrestEA DIAG: WriteInitSnapshot: writing DECISION_SUMMARY");
   WriteToAllFiles(decCsv, decRaw);
}

// --------------------------- BAR SHIFT HELPER -----------------------
int GetBarShift(string symbol, ENUM_TIMEFRAMES timeframe, datetime time)
{
   // MQL5 doesn't have iBarShift, so we implement it using Bars
   // Returns the shift (index) of the bar with the specified time
   // Returns -1 if the bar is not found
   
   if(time < 0) return -1;
   
   datetime time_arr[];
   ArraySetAsSeries(time_arr, true);
   
   // Copy a reasonable number of bars to search through
   int copied = CopyTime(symbol, timeframe, 0, 5000, time_arr);
   if(copied <= 0) return -1;
   
   // Find the bar with time <= requested time (closest bar not newer than requested time)
   for(int i = 0; i < copied; i++)
   {
      if(time_arr[i] <= time)
      {
         return i;
      }
   }
   
   return -1; // Not found
}

// --------------------------- BATCH PROCESSING -----------------------
void BatchProcessRange(datetime from_time, datetime to_time)
{
   if(!EnsureMacdHandle())
   {
      Print("WaveCrestEA DIAG: BatchProcessRange: macd handle not available");
      return;
   }

   if(from_time > to_time)
   {
      datetime tmp = from_time;
      from_time = to_time;
      to_time = tmp;
   }

   int shiftFrom = GetBarShift(_Symbol, PERIOD_CURRENT, from_time);
   int shiftTo   = GetBarShift(_Symbol, PERIOD_CURRENT, to_time);

   if(shiftFrom < 0 || shiftTo < 0)
   {
      PrintFormat("WaveCrestEA DIAG: BatchProcessRange: iBarShift failed shiftFrom=%d shiftTo=%d", shiftFrom, shiftTo);
      // fallback via CopyRates scan
      MqlRates tmpRates[];
      int copied = CopyRates(_Symbol, PERIOD_CURRENT, 0, 5000, tmpRates);
      if(copied <= 0) { Print("WaveCrestEA DIAG: BatchProcessRange fallback CopyRates failed"); return; }
      int foundFrom=-1, foundTo=-1;
      for(int i=0;i<copied;i++)
      {
         if(foundFrom==-1 && tmpRates[i].time <= from_time) foundFrom = i;
         if(foundTo==-1 && tmpRates[i].time <= to_time) foundTo = i;
         if(foundFrom!=-1 && foundTo!=-1) break;
      }
      if(foundFrom==-1 || foundTo==-1) { Print("WaveCrestEA DIAG: fallback couldn't find bars"); return; }
      shiftFrom = foundFrom; shiftTo = foundTo;
      PrintFormat("WaveCrestEA DIAG: BatchProcessRange fallback shifts shiftFrom=%d shiftTo=%d", shiftFrom, shiftTo);
   }

   int startShift = MathMax(shiftFrom, shiftTo);
   int endShift   = MathMin(shiftFrom, shiftTo);

   PrintFormat("WaveCrestEA DIAG: BatchProcessRange processing shifts %d down to %d", startShift, endShift);

   int processed=0, skipped=0;
   for(int s = startShift; s >= endShift; --s)
   {
      MqlRates rates[];
      int copiedRates = CopyRates(_Symbol, PERIOD_CURRENT, s, 3, rates); // need at least now + prev
      if(copiedRates < 2) { skipped++; continue; }

      datetime nowBarTime  = rates[0].time;
      datetime prevBarTime = rates[1].time;

      int closedOffset = s;
      int requestCount = 3;
      WaitForMacdMainAndSignal(closedOffset, requestCount, 6, 200);

      double mainBuf[], sigBuf[];
      ArrayResize(mainBuf, requestCount);
      ArrayResize(sigBuf, requestCount);
      int gotMain = CopyBuffer(macdHandle, 0, closedOffset, requestCount, mainBuf);
      int gotSig  = CopyBuffer(macdHandle, 1, closedOffset, requestCount, sigBuf);
      // defensive: if we don't have at least 2 points, mark haveMacd=false and write NODATA
      bool haveMacd = (gotMain >= 2 && gotSig >= 2);

      double main_now=0.0, main_prev=0.0, signal_now=0.0, signal_prev=0.0;
      double hist_now=0.0, hist_prev=0.0;

      if(haveMacd)
      {
         main_now = mainBuf[0]; main_prev = mainBuf[1];
         signal_now = sigBuf[0]; signal_prev = sigBuf[1];
         hist_now = main_now - signal_now;
         hist_prev = main_prev - signal_prev;
      }
      else
      {
         // try per-bar fallback; require both now and prev for both buffers
         double mNow[], mPrev[], sNow[], sPrev[];
         int mNowCount  = CopyBuffer(macdHandle, 0, closedOffset,    1, mNow);
         int mPrevCount = CopyBuffer(macdHandle, 0, closedOffset+1,  1, mPrev);
         int sNowCount  = CopyBuffer(macdHandle, 1, closedOffset,    1, sNow);
         int sPrevCount = CopyBuffer(macdHandle, 1, closedOffset+1,  1, sPrev);
         if(mNowCount>0 && mPrevCount>0 && sNowCount>0 && sPrevCount>0)
         {
            main_now = mNow[0]; main_prev = mPrev[0];
            signal_now = sNow[0]; signal_prev = sPrev[0];
            hist_now = main_now - signal_now;
            hist_prev = main_prev - signal_prev;
            haveMacd = true;
         }
      }

      // ensure usedCarryPrev exists (batch doesn't use carry logic but variable is referenced in decision rows)
      bool usedCarryPrev = false;

      double predicted_hist_now = 0.0;
      double residual = 0.0;
      if(haveMacd)
      {
         double alpha = 2.0 / (MACD_Signal + 1.0);
         if(!DisablePredictor) predicted_hist_now = hist_prev + (1.0 - alpha) * (main_now - main_prev);
         else predicted_hist_now = hist_now;
         residual = hist_now - predicted_hist_now;
      }

      double atr = 0.0;
      if(atrHandle != INVALID_HANDLE)
      {
         double atrBuf[]; int ac = CopyBuffer(atrHandle, 0, closedOffset, 1, atrBuf); if(ac>0) atr = atrBuf[0];
      }
      double eps = ComputeEpsilon(atr);
      double safeEps = MathMax(eps, PointSize()*1e-12);
      double normResidual = (safeEps>0.0) ? (residual / safeEps) : 0.0;

      double rsi = 50.0;
      if(rsiHandle != INVALID_HANDLE)
      {
         double rsiBuf[]; int rc = CopyBuffer(rsiHandle, 0, closedOffset, 1, rsiBuf); if(rc>0) rsi = rsiBuf[0];
      }

      double eps_input = HistOvershootThreshold;
      int roundingDigits = 1;
      if(RoundingDigitsOverride > 0) roundingDigits = RoundingDigitsOverride;
      else if(eps_input > 0.0) roundingDigits = (int)MathMax(1.0, MathCeil(-MathLog10(eps_input)));

      double main_prev_r   = NormalizeDouble(main_prev, roundingDigits);
      double main_now_r    = NormalizeDouble(main_now, roundingDigits);
      double signal_prev_r = NormalizeDouble(signal_prev, roundingDigits);
      double signal_now_r  = NormalizeDouble(signal_now, roundingDigits);
      double hist_prev_r   = NormalizeDouble(main_prev_r - signal_prev_r, roundingDigits);
      double hist_now_r    = NormalizeDouble(main_now_r - signal_now_r, roundingDigits);

      // ordering and overshoot use magnitude comparisons (MathAbs)
      double orderingGap = MathAbs(MathAbs(signal_now_r) - MathAbs(main_now_r));
      bool orderingSwappedBuy  = (MathAbs(main_prev_r) > MathAbs(signal_prev_r)) && (MathAbs(signal_now_r) > MathAbs(main_now_r));
      bool orderingSwappedSell = (MathAbs(signal_prev_r) > MathAbs(main_prev_r)) && (MathAbs(main_now_r) > MathAbs(signal_now_r));

      // eps_compare: treat non-positive eps_input as "use MinOrderingGap"
      double eps_compare;
      if(eps_input <= 0.0) eps_compare = MinOrderingGap;
      else eps_compare = MathMax(MathAbs(eps_input), MinOrderingGap);

      bool orderingGapLargeEnough = (ForcePassOrderingGap) ? true : (orderingGap > eps_compare);

      bool mainSignalSameSign = (main_now * signal_now) > 0.0;
      bool histLargeEnough = (MathAbs(hist_now_r) >= (MinHistAbsMult * safeEps));

      bool perBarEmergentBuy=false, perBarEmergentSell=false;
      if(haveMacd && mainSignalSameSign && histLargeEnough)
      {
         // Determine side purely by sign of main_now & hist_now (no zero-cross detection).
         if(main_now < 0.0 && hist_now < 0.0)
         {
            if(DisablePredictor) perBarEmergentBuy = true;
            else if(normResidual <= -Emergence_kResidual) perBarEmergentBuy = true;
         }
         if(main_now > 0.0 && hist_now > 0.0)
         {
            if(DisablePredictor) perBarEmergentSell = true;
            else if(normResidual >= Emergence_kResidual) perBarEmergentSell = true;
         }
      }

      int allowEntry=0, isBuy=0, isSell=0;
      int blockedByRSI=0, blockedByOvershoot=0, blockedByNoSL=0, blockedByLots=0;

      double entry = rates[0].close;
      double sl=0.0, tp=0.0, lots=0.0;
      double slDistance = (atr>0.0) ? atr * ATR_Multiplier : PointSize()*50.0;

      if(perBarEmergentBuy || perBarEmergentSell)
      {
         if(perBarEmergentBuy) { allowEntry = 1; isBuy = 1; }
         if(perBarEmergentSell) { allowEntry = 1; isSell = 1; }
         if(isBuy && rsi >= RSI_Buy_Threshold) { blockedByRSI = 1; allowEntry = 0; isBuy = 0; }
         if(isSell && rsi <= RSI_Sell_Threshold) { blockedByRSI = 1; allowEntry = 0; isSell = 0; }

         if(isBuy)
         {
            // buy requires magnitude ordering (main was stronger then signal, now signal stronger than main)
            if(!orderingSwappedBuy || !orderingGapLargeEnough)
            {
               blockedByOvershoot = 1; allowEntry = 0; isBuy = 0; isSell = 0;
            }
         }
         else if(isSell)
         {
            // sell requires magnitude ordering (signal was stronger then main, now main stronger than signal)
            if(!orderingSwappedSell || !orderingGapLargeEnough)
            {
               blockedByOvershoot = 1; allowEntry = 0; isBuy = 0; isSell = 0;
            }
         }

         if(slDistance <= 0.0) { blockedByNoSL = 1; allowEntry = 0; isBuy = 0; isSell = 0; }
         else
         {
            sl = isBuy ? (entry - slDistance) : (entry + slDistance);
            tp = isBuy ? (entry + TP_Multiplier * slDistance) : (entry - TP_Multiplier * slDistance);
            double computedLots = CalcLotsForEntry(entry, sl);
            lots = computedLots;
            if(lots <= 0.0 && ForceMinLots > 0.0) lots = ForceMinLots; // temporary testing fallback
            if(lots <= 0.0) { blockedByLots = 1; allowEntry = 0; isBuy = 0; isSell = 0; }
         }
      }

      string now_ts  = TimeStampOrNA(nowBarTime);
      string prev_ts = TimeStampOrNA(prevBarTime);

      string macdRaw;
      if(haveMacd)
         macdRaw = StringFormat("%s,MACD_DEBUG,signal_prev=%.8g@%s,signal_now=%.8g@%s,hist_prev=%.8g@%s,hist_now=%.8g@%s,main_prev=%.8g,main_now=%.8g,predicted_hist=%.8g,residual=%.8g,normResidual=%.6g,safeEps=%.8g,eps=%.8g,atr=%.8g,rsi=%.8g\n",
                                now_ts, signal_prev, prev_ts,
                                signal_now,  now_ts,
                                hist_prev,   prev_ts,
                                hist_now,    now_ts,
                                main_prev, main_now, predicted_hist_now, residual, normResidual, safeEps, eps, atr, rsi);
      else
         macdRaw = StringFormat("%s,MACD_DEBUG,NODATA - MACD buffers not available for this closed bar\n", now_ts);

      // Debug print: ordering/gap/lot decisions (batch)
      double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      double volStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
      PrintFormat("DBG_ORDER %s eps_input=%.6g MinOrderingGap=%.6g eps_compare=%.6g orderingGap=%.6g orderingGapLargeEnough=%d orderingSwappedBuy=%d orderingSwappedSell=%d computedLots=%.5g lots=%.5g minLot=%.5g volStep=%.5g freeMargin=%.2f",
                  now_ts, eps_input, MinOrderingGap, eps_compare, orderingGap, orderingGapLargeEnough?1:0, orderingSwappedBuy?1:0, orderingSwappedSell?1:0, CalcLotsForEntry(entry, sl), lots, minLot, volStep, AccountInfoDouble(ACCOUNT_MARGIN_FREE));

      string decisionRaw = StringFormat("%s,DECISION_SUMMARY,allowEntry=%d,isBuy=%d,isSell=%d,blockedByRSI=%d,blockedByOvershoot=%d,blockedByNoSL=%d,slDistance=%.8g,computedLots=%.8g,lots=%.8g,entry=%.8g,sl=%.8g,tp=%.8g,rnd=%d,gap=%.8g,eps_input=%.8g,carryPrev=%d,predictorDisabled=%d\n",
                                       now_ts, allowEntry, isBuy, isSell, blockedByRSI, blockedByOvershoot, blockedByNoSL, slDistance, CalcLotsForEntry(entry, sl), lots, entry, sl, tp, roundingDigits, orderingGap, eps_input, usedCarryPrev?1:0, DisablePredictor?1:0);

      WriteToAllFiles("", macdRaw);
      WriteToAllFiles("", decisionRaw);

      processed++;
      Sleep(1);
   }

   PrintFormat("WaveCrestEA DIAG: BatchProcessRange finished for %s - %s processed=%d skipped=%d", TimeToString(from_time, TIME_DATE|TIME_SECONDS), TimeToString(to_time, TIME_DATE|TIME_SECONDS), processed, skipped);
}

// --------------------------- LIFECYCLE -------------------------------
int OnInit()
{
   macdHandle = iMACD(_Symbol, PERIOD_CURRENT, MACD_Fast, MACD_Slow, MACD_Signal, PRICE_CLOSE);
   atrHandle  = iATR(_Symbol, PERIOD_CURRENT, ATR_Period);
   rsiHandle  = iRSI(_Symbol, PERIOD_CURRENT, RSI_Period, PRICE_CLOSE);

   lastProcessedBarTime = 0;
   barsSinceLastEntry = 9999;
   consecutiveLosses = 0;

   OpenDebugFiles();

   snapshotPending = true;

   if(UseTestDateRange)
   {
      if(TestFromDate >= TestToDate)
      {
         Print("WaveCrestEA DIAG: UseTestDateRange is enabled but TestFromDate >= TestToDate. Skipping batch.");
      }
      else
      {
         BatchProcessRange(TestFromDate, TestToDate);
      }
   }

   EventSetTimer(1);

   PrintFormat("WaveCrestEA DIAG: Initialized. MACD(%d,%d,%d) UseTestDateRange=%d From=%s To=%s UseCarryPrev=%d DisablePredictor=%d MinOrderingGap=%.8g ForcePassOrderingGap=%d ForceMinLots=%.8g RndOverride=%d",
               MACD_Fast, MACD_Slow, MACD_Signal, UseTestDateRange?1:0, TimeToString(TestFromDate, TIME_DATE|TIME_SECONDS), TimeToString(TestToDate, TIME_DATE|TIME_SECONDS),
               UseCarryPrev?1:0, DisablePredictor?1:0, MinOrderingGap, ForcePassOrderingGap?1:0, ForceMinLots, RoundingDigitsOverride);
   return(INIT_SUCCEEDED);
}

void OnTimer()
{
   if(snapshotPending)
   {
      bool ok = WaitForMacdMainAndSignal(1, 3, 8, 250);
      if(!ok) Print("WaveCrestEA DIAG: OnTimer initial WaitForMacdMainAndSignal timed out");
      WriteInitSnapshot();
      snapshotPending = false;
   }
   OnTick();
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   CloseDebugFiles();
   if(macdHandle != INVALID_HANDLE) IndicatorRelease(macdHandle);
   if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
   if(rsiHandle != INVALID_HANDLE) IndicatorRelease(rsiHandle);
   PrintFormat("WaveCrestEA DIAG: Deinit reason=%d", reason);
}

// Handle deals to track consecutive losses
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   ulong dealTicket = trans.deal;
   if(dealTicket == 0) return;
   string dsym = HistoryDealGetString(dealTicket, DEAL_SYMBOL);
   if(dsym != _Symbol) return;
   double profit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
   if(profit < 0.0)
   {
      consecutiveLosses++;
      if(consecutiveLosses > MaxDoublings) consecutiveLosses = MaxDoublings;
      PrintFormat("WaveCrestEA DIAG: Loss deal profit=%.8g consecutiveLosses=%d", profit, consecutiveLosses);
   }
   else
   {
      if(consecutiveLosses != 0) PrintFormat("WaveCrestEA DIAG: Win/BE deal profit=%.8g resetting consecutiveLosses %d->0", profit, consecutiveLosses);
      consecutiveLosses = 0;
   }
}

// --------------------------- MAIN LOGIC (closed-bar) -----------------
void OnTick()
{
   MqlRates rates[];
   int copiedRates = CopyRates(_Symbol, PERIOD_CURRENT, 0, 3, rates);
   if(copiedRates < 2) return;
   datetime closedBarTime = rates[1].time;
   if(closedBarTime == lastProcessedBarTime) return;
   lastProcessedBarTime = closedBarTime;

   int closedOffset = 1;
   int requestCount = 3;

   if(!EnsureMacdHandle())
   {
      string ts_no = TimeStampOrNA(closedBarTime);
      string noCsv = StringFormat("\"%s\",\"MACD_DEBUG\",NODATA\r\n", ts_no);
      string noRaw = StringFormat("%s,MACD_DEBUG,NODATA - macd handle invalid\n", ts_no);
      WriteToAllFiles(noCsv, noRaw);
      return;
   }

   WaitForMacdMainAndSignal(closedOffset, requestCount, 6, 200);

   double mainBuf[], sigBuf[];
   ArrayResize(mainBuf, requestCount);
   ArrayResize(sigBuf, requestCount);
   int gotMain = CopyBuffer(macdHandle, 0, closedOffset, requestCount, mainBuf);
   int gotSig  = CopyBuffer(macdHandle, 1, closedOffset, requestCount, sigBuf);
   PrintFormat("WaveCrestEA DIAG: OnTick CopyBuffer gotMain=%d gotSig=%d GetLastError=%d", gotMain, gotSig, GetLastError());

   bool haveMacd = (gotMain >= 2 && gotSig >= 2);

   double main_now=0.0, main_prev=0.0, signal_now=0.0, signal_prev=0.0;
   double hist_now=0.0, hist_prev=0.0;

   datetime prevBarTime = 0, nowBarTime = 0;
   MqlRates timesBuf[];
   int copiedTimes = CopyRates(_Symbol, PERIOD_CURRENT, closedOffset, 3, timesBuf);
   if(copiedTimes > 1)
   {
      nowBarTime  = timesBuf[0].time;
      prevBarTime = timesBuf[1].time;
   }
   else
   {
      nowBarTime = TimeCurrent();
      prevBarTime = lastLoggedNowTime;
   }

   if(haveMacd)
   {
      if(gotMain >= 2 && gotSig >= 2)
      {
         main_now = mainBuf[0]; main_prev = mainBuf[1];
         signal_now = sigBuf[0]; signal_prev = sigBuf[1];
         hist_now = main_now - signal_now;
         hist_prev = main_prev - signal_prev;
      }
      else haveMacd = false;
   }
   else
   {
      double mNow[], mPrev[], sNow[], sPrev[];
      int mNowCount  = CopyBuffer(macdHandle, 0, closedOffset,    1, mNow);
      int mPrevCount = CopyBuffer(macdHandle, 0, closedOffset+1,  1, mPrev);
      int sNowCount  = CopyBuffer(macdHandle, 1, closedOffset,    1, sNow);
      int sPrevCount = CopyBuffer(macdHandle, 1, closedOffset+1,  1, sPrev);
      PrintFormat("WaveCrestEA DIAG: per-bar fallback mNow=%d mPrev=%d sNow=%d sPrev=%d GetLastError=%d", mNowCount, mPrevCount, sNowCount, sPrevCount, GetLastError());
      if(mNowCount>0 && mPrevCount>0 && sNowCount>0 && sPrevCount>0)
      {
         main_now = mNow[0]; main_prev = mPrev[0];
         signal_now = sNow[0]; signal_prev = sPrev[0];
         hist_now = main_now - signal_now;
         hist_prev = main_prev - signal_prev;
         haveMacd = true;
      }
   }

   bool usedCarryPrev = false;
   if(UseCarryPrev && prevBarTime != 0 && lastLoggedNowTime == prevBarTime)
   {
      main_prev = lastLoggedNow_main;
      signal_prev = lastLoggedNow_signal;
      hist_prev = lastLoggedNow_hist;
      usedCarryPrev = true;
      PrintFormat("WaveCrestEA DIAG: Carrying previous from lastLoggedNowTime=%s for prevBarTime=%s", TimeStampOrNA(lastLoggedNowTime), TimeStampOrNA(prevBarTime));
   }

   double predicted_hist_now = 0.0;
   double residual = 0.0;

   if(haveMacd)
   {
      double alpha = 2.0 / (MACD_Signal + 1.0);
      if(!DisablePredictor)
      {
         predicted_hist_now = hist_prev + (1.0 - alpha) * (main_now - main_prev);
         residual = hist_now - predicted_hist_now;
      }
      else
      {
         predicted_hist_now = hist_now;
         residual = 0.0;
      }
   }

   double atr = 0.0;
   if(atrHandle != INVALID_HANDLE)
   {
      double atrBuf[]; int ac = CopyBuffer(atrHandle, 0, closedOffset, 1, atrBuf); if(ac>0) atr = atrBuf[0];
   }
   double eps = ComputeEpsilon(atr);
   double safeEps = MathMax(eps, PointSize()*1e-12);
   double normResidual = (safeEps > 0.0) ? residual / safeEps : 0.0;

   double rsi = 50.0;
   if(rsiHandle != INVALID_HANDLE)
   {
      double rsiBuf[]; int rc = CopyBuffer(rsiHandle, 0, closedOffset, 1, rsiBuf); if(rc>0) rsi = rsiBuf[0];
   }

   double eps_input = HistOvershootThreshold;
   int roundingDigits = 1;
   if(RoundingDigitsOverride > 0) roundingDigits = RoundingDigitsOverride;
   else if(eps_input > 0.0) roundingDigits = (int)MathMax(1.0, MathCeil(-MathLog10(eps_input)));

   double main_prev_r   = NormalizeDouble(main_prev, roundingDigits);
   double main_now_r    = NormalizeDouble(main_now, roundingDigits);
   double signal_prev_r = NormalizeDouble(signal_prev, roundingDigits);
   double signal_now_r  = NormalizeDouble(signal_now, roundingDigits);
   double hist_prev_r   = NormalizeDouble(main_prev_r - signal_prev_r, roundingDigits);
   double hist_now_r    = NormalizeDouble(main_now_r - signal_now_r, roundingDigits);

   double orderingGap = MathAbs(MathAbs(signal_now_r) - MathAbs(main_now_r));
   bool orderingSwappedBuy  = (MathAbs(main_prev_r) > MathAbs(signal_prev_r)) && (MathAbs(signal_now_r) > MathAbs(main_now_r));
   bool orderingSwappedSell = (MathAbs(signal_prev_r) > MathAbs(main_prev_r)) && (MathAbs(main_now_r) > MathAbs(signal_now_r));

   // eps_compare: treat non-positive eps_input as "use MinOrderingGap"
   double eps_compare;
   if(eps_input <= 0.0) eps_compare = MinOrderingGap;
   else eps_compare = MathMax(MathAbs(eps_input), MinOrderingGap);

   bool orderingGapLargeEnough = (ForcePassOrderingGap) ? true : (orderingGap > eps_compare);

   bool mainSignalSameSign = (main_now * signal_now) > 0.0;
   bool histLargeEnough = (MathAbs(hist_now_r) >= (MinHistAbsMult * safeEps));
   bool perBarEmergentBuy = false, perBarEmergentSell = false;
   if(haveMacd && mainSignalSameSign && histLargeEnough)
   {
      if(main_now < 0.0 && hist_now < 0.0)
      {
         if(DisablePredictor) perBarEmergentBuy = true;
         else if(normResidual <= -Emergence_kResidual) perBarEmergentBuy = true;
      }
      if(main_now > 0.0 && hist_now > 0.0)
      {
         if(DisablePredictor) perBarEmergentSell = true;
         else if(normResidual >=  Emergence_kResidual) perBarEmergentSell = true;
      }
   }

   int allowEntry = 0, isBuy = 0, isSell = 0;
   int blockedByRSI = 0, blockedByOvershoot = 0, blockedByNoSL = 0, blockedByLots = 0;

   double entry = rates[1].close; // safe because copiedRates >= 2 above
   double sl = 0.0, tp = 0.0, lots = 0.0;
   double slDistance = (atr>0.0) ? atr * ATR_Multiplier : PointSize()*50.0;

   if(perBarEmergentBuy || perBarEmergentSell)
   {
      if(perBarEmergentBuy) { allowEntry = 1; isBuy = 1; }
      if(perBarEmergentSell) { allowEntry = 1; isSell = 1; }

      if(isBuy && rsi >= RSI_Buy_Threshold) { blockedByRSI = 1; allowEntry = 0; isBuy = 0; }
      if(isSell && rsi <= RSI_Sell_Threshold) { blockedByRSI = 1; allowEntry = 0; isSell = 0; }

      if(isBuy)
      {
         if(!orderingSwappedBuy || !orderingGapLargeEnough)
         {
            blockedByOvershoot = 1; allowEntry = 0; isBuy = 0; isSell = 0;
         }
      }
      else if(isSell)
      {
         if(!orderingSwappedSell || !orderingGapLargeEnough)
         {
            blockedByOvershoot = 1; allowEntry = 0; isBuy = 0; isSell = 0;
         }
      }

      if(slDistance <= 0.0) { blockedByNoSL = 1; allowEntry = 0; isBuy = 0; isSell = 0; }
      else
      {
         sl = isBuy ? (entry - slDistance) : (entry + slDistance);
         tp = isBuy ? (entry + TP_Multiplier * slDistance) : (entry - TP_Multiplier * slDistance);
         double computedLots = CalcLotsForEntry(entry, sl);
         lots = computedLots;
         if(lots <= 0.0 && ForceMinLots > 0.0) lots = ForceMinLots; // temporary testing fallback
         if(lots <= 0.0) { blockedByLots = 1; allowEntry = 0; isBuy = 0; isSell = 0; }
      }
   }

   string tsBar = TimeStampOrNA(closedBarTime);
   string macdCsv;
   if(haveMacd)
      macdCsv = StringFormat("\"%s\",\"MACD_DEBUG\",signal_prev=%.8g@%s,signal_now=%.8g@%s,hist_prev=%.8g@%s,hist_now=%.8g@%s,main_prev=%.8g,main_now=%.8g@%s,predicted_hist=%.8g,residual=%.8g,normResidual=%.6g,safeEps=%.8g,eps=%.8g,atr=%.8g,rsi=%.8g\r\n",
                             tsBar,
                             signal_prev, TimeStampOrNA(prevBarTime),
                             signal_now,  TimeStampOrNA(nowBarTime),
                             hist_prev,   TimeStampOrNA(prevBarTime),
                             hist_now,    TimeStampOrNA(nowBarTime),
                             main_prev, TimeStampOrNA(prevBarTime), main_now, TimeStampOrNA(nowBarTime),
                             predicted_hist_now, residual, normResidual, safeEps, eps, atr, rsi);
   else
      macdCsv = StringFormat("\"%s\",\"MACD_DEBUG\",NODATA\r\n", tsBar);

   string macdRaw;
   if(haveMacd)
      macdRaw = StringFormat("%s,MACD_DEBUG,signal_prev=%.8g@%s,signal_now=%.8g@%s,hist_prev=%.8g@%s,hist_now=%.8g@%s,main_prev=%.8g,main_now=%.8g,predicted_hist=%.8g,residual=%.8g,normResidual=%.6g,safeEps=%.8g,eps=%.8g,atr=%.8g,rsi=%.8g\n",
                             tsBar, signal_prev, TimeStampOrNA(prevBarTime),
                             signal_now,  TimeStampOrNA(nowBarTime),
                             hist_prev,   TimeStampOrNA(prevBarTime),
                             hist_now,    TimeStampOrNA(nowBarTime),
                             main_prev, main_now, predicted_hist_now, residual, normResidual, safeEps, eps, atr, rsi);
   else
      macdRaw = StringFormat("%s,MACD_DEBUG,NODATA - MACD buffers not available for this closed bar\n", tsBar);

   WriteToAllFiles(macdCsv, macdRaw);

   string decisionNotes = StringFormat("decision_snapshot rnd=%d gap=%.8g eps_input=%.8g eps_compare=%.8g orderingSwappedBuy=%d orderingSwappedSell=%d orderingGapLargeEnough=%d carryPrevUsed=%d predictorDisabled=%d",
                                       roundingDigits, orderingGap, eps_input, eps_compare, orderingSwappedBuy?1:0, orderingSwappedSell?1:0, orderingGapLargeEnough?1:0, usedCarryPrev?1:0, DisablePredictor?1:0);

   string decisionCsv = StringFormat("\"%s\",\"DECISION_SUMMARY\",signal_prev=%.8g@%s,signal_now=%.8g@%s,hist_prev=%.8g@%s,hist_now=%.8g@%s,main_prev=%.8g,main_now=%.8g,predicted_hist=%.8g,residual=%.8g,allowEntry=%d,isBuy=%d,isSell=%d,blockedByRSI=%d,blockedByOvershoot=%d,blockedByNoSL=%d,slDistance=%.8g,lots=%.8g,entry=%.8g,sl=%.8g,tp=%.8g,consecLosses=%d,notes=\"%s\"\r\n",
                                    tsBar,
                                    signal_prev, TimeStampOrNA(prevBarTime),
                                    signal_now,  TimeStampOrNA(nowBarTime),
                                    hist_prev,   TimeStampOrNA(prevBarTime),
                                    hist_now,    TimeStampOrNA(nowBarTime),
                                    main_prev, main_now, predicted_hist_now, residual,
                                    allowEntry, isBuy, isSell,
                                    blockedByRSI, blockedByOvershoot, blockedByNoSL,
                                    slDistance, lots, entry, sl, tp, consecutiveLosses,
                                    decisionNotes);

   string decisionRaw = StringFormat("%s,DECISION_SUMMARY,allowEntry=%d,isBuy=%d,isSell=%d,blockedByRSI=%d,blockedByOvershoot=%d,blockedByNoSL=%d,slDistance=%.8g,computedLots=%.8g,lots=%.8g,entry=%.8g,sl=%.8g,tp=%.8g,rnd=%d,gap=%.8g,eps_input=%.8g,carryPrev=%d,predictorDisabled=%d\n",
                                    tsBar, allowEntry, isBuy, isSell, blockedByRSI, blockedByOvershoot, blockedByNoSL, slDistance, CalcLotsForEntry(entry, sl), lots, entry, sl, tp, roundingDigits, orderingGap, eps_input, usedCarryPrev?1:0, DisablePredictor?1:0);

   WriteToAllFiles(decisionCsv, decisionRaw);

   lastLoggedNowTime = nowBarTime;
   lastLoggedNow_main = main_now;
   lastLoggedNow_signal = signal_now;
   lastLoggedNow_hist = hist_now;

   if(allowEntry)
   {
      string comment = StringFormat("WaveCrestEA chartHist=%.8g signal=%.8g dbl=%d mul=%.3g", hist_prev, signal_prev, consecutiveLosses, LossMultiplier);
      bool sent = PlaceOrder(isBuy==1, lots, sl, tp, comment);
      if(sent)
      {
         PrintFormat("WaveCrestEA: ORDER_PLACED %s lots=%.2f", (isBuy? "BUY":"SELL"), lots);
         barsSinceLastEntry = 0;
         look_for = 0;
      }
      else
      {
         Print("WaveCrestEA: Order failed to send.");
      }
   }

   barsSinceLastEntry++;
}
//+------------------------------------------------------------------+