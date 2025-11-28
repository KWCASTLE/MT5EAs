//+------------------------------------------------------------------+
//| EbbAndFlowEA - extended fallback + CSV logging                   |
//| - Primary: OnTradeTransaction updates consecutiveLosses immediately. |
//| - Fallback: immediate scan with HistorySelect; deferred retries   |
//|   extended.                                                         |
//| - CSV logging: writes diagnostic events to MQL5 Files folder for   |
//|   offline analysis.                                                 |
//| - Added input: LossMultiplier - configurable multiplier applied   |
//|   to risk after each sequential loss (replaces fixed 2x doubling)  |
//+------------------------------------------------------------------+
#property strict
#include <Trade\Trade.mqh>
#include <Trade\DealInfo.mqh>
CTrade trade;

// --------------------------- PROTOTYPES -----------------------------
void TryProcessPendingHistory();
bool SumRecentClosingDealsForSymbol(int lookback, double &sumProfit, int &dealsCount);
bool SumDealsForPositionByTicket(ulong positionTicket, double &sumProfit, int &dealsCount);
bool PlaceFollowTrade(bool priceMovedUp, datetime triggeredBarTime);
double CalcLotsWithDoubling(double entry, double stopPrice);
void LogCSV(string row);

// --------------------------- INPUTS -------------------------------
input double FixedLotForTesting = 0.0;      // 0 = use risk %, >0 forces fixed lots
input double RiskPercentPerTrade = 0.5;     // base risk percent of free margin
input int    MaxDoublings = 5;              // cap for doubling
input double LossMultiplier = 2.0;          // multiplier applied per sequential loss (was fixed 2x)
input int    MovePoints = 100;              // trigger distance (points)
input int    StopLossPoints = 50;           // SL in points
input int    TakeProfitPoints = 100;        // TP in points
input int    DeferredLookbackDeals = 20;    // how many recent deals to sum for fallback
input int    DeferredMaxAttempts = 60;      // extended deferred attempts before give-up
input int    HistorySelectSeconds = 3600;   // HistorySelect window (seconds) for immediate & deferred scans
input bool   PrintTradeInfo = true;         // verbose logging
input bool   CsvLogging = true;             // write CSV rows for key events

// --------------------------- GLOBALS -------------------------------
datetime lastClosedBarTime = 0;
double   referencePrice = 0.0;
bool     waitingForMove = true;

ulong    lastPlacedPositionTicket = 0; // best-effort tracking of last opened position
bool     positionWasOpen = false;      // whether a position existed last tick
int      consecutiveLosses = 0;
int      maxBuf = 512;
ulong    activeTicket = 0;

// Deferred fallback processing state
bool     pendingHistoryCheck = false;
int      pendingHistoryAttempts = 0;
int      pendingHistoryMaxAttempts = DeferredMaxAttempts; // default value assigned from input on init

// Flag: set when consecutiveLosses reached the cap (resets after capped trade placed)
bool     reachedDoublingCap = false;

// CSV filename
string   csvFilename = "EbbAndFlowEA_log.csv";

// --------------------------- HELPERS -------------------------------
double PointSize() { return(SymbolInfoDouble(_Symbol, SYMBOL_POINT)); }
double Ask()       { return(SymbolInfoDouble(_Symbol, SYMBOL_ASK)); }
double Bid()       { return(SymbolInfoDouble(_Symbol, SYMBOL_BID)); }

void Log(string s)
{
   if(PrintTradeInfo) Print(TimeToString(TimeCurrent(), TIME_SECONDS), " EbbAndFlowEA: ", s);
   if(CsvLogging)
   {
      // Also write a CSV row for console logs
      string row = StringFormat("%s,LOG,%s", TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS), s);
      LogCSV(row);
   }
}

void LogCSV(string row)
{
   if(!CsvLogging) return;
   int handle = FileOpen(csvFilename, FILE_READ|FILE_WRITE|FILE_ANSI|FILE_CSV);
   if(handle == INVALID_HANDLE)
   {
      // try create
      handle = FileOpen(csvFilename, FILE_WRITE|FILE_ANSI|FILE_CSV);
      if(handle == INVALID_HANDLE)
      {
         // give up silently
         return;
      }
   }
   // append
   FileSeek(handle, 0, SEEK_END);
   // write string and newline (FileWriteString doesn't automatically append newline)
   FileWriteString(handle, row);
   FileWriteString(handle, "\r\n");
   FileFlush(handle);
   FileClose(handle);
}

// --------------------------- HISTORY HELPERS (NO INTEGER CALLS) ------------------------
// Conservative fallback: sum recent non-zero deals for the symbol (treat as closing deals).
bool SumDealsForPositionByTicket(ulong positionTicket, double &sumProfit, int &dealsCount)
{
   sumProfit = 0.0;
   dealsCount = 0;
   int totalDeals = HistoryDealsTotal();
   if(totalDeals <= 0) return false;

   int found = 0;
   int limit = MathMin(totalDeals, 500);
   for(int i = totalDeals - 1; i >= totalDeals - limit; i--)
   {
      if(i < 0) break;
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0) continue;
      string dsym = HistoryDealGetString(dealTicket, DEAL_SYMBOL);
      if(dsym != _Symbol) continue;
      double p = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
      if(p == 0.0) continue;
      sumProfit += p;
      dealsCount++;
      found++;
      if(found >= limit) break;
   }
   return (dealsCount > 0);
}

// Sum last N recent deals for symbol treating non-zero-profit deals as closing deals (defensive)
bool SumRecentClosingDealsForSymbol(int lookback, double &sumProfit, int &dealsCount)
{
   sumProfit = 0.0;
   dealsCount = 0;
   int totalDeals = HistoryDealsTotal();
   if(totalDeals <= 0) return false;

   int found = 0;
   for(int i = totalDeals - 1; i >= 0 && found < lookback; i--)
   {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0) continue;
      string dsym = HistoryDealGetString(dealTicket, DEAL_SYMBOL);
      if(dsym != _Symbol) continue;
      double p = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
      if(p == 0.0) continue;
      sumProfit += p;
      dealsCount++;
      found++;
   }
   return (dealsCount > 0);
}

// --------------------------- TRADE TRANSACTION (PRIMARY) -----------------
// Primary reliable handler: update consecutiveLosses based on deal profit immediately.
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   ulong dealTicket = trans.deal;
   if(dealTicket == 0) return;

   // stable history reads
   string dsym = HistoryDealGetString(dealTicket, DEAL_SYMBOL);
   if(dsym != _Symbol) return;

   double profit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
   Log(StringFormat("OnTradeTransaction: DEAL_ADD ticket=%I64u symbol=%s profit=%.2f", dealTicket, dsym, profit));
   if(CsvLogging) LogCSV(StringFormat("%s,DEAL,deal=%I64u,profit=%.5f,consecutiveLossesBefore=%d", TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS), dealTicket, profit, consecutiveLosses));

   // Only strict negative profit is counted as a loss
   if(profit < 0.0)
   {
      consecutiveLosses++;
      if(consecutiveLosses >= MaxDoublings)
      {
         consecutiveLosses = MaxDoublings;
         reachedDoublingCap = true;
         Log(StringFormat("consecutiveLosses reached cap (%d). reachedDoublingCap set=true", MaxDoublings));
         if(CsvLogging) LogCSV(StringFormat("%s,EVENT,cap_reached,consecutiveLosses=%d", TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS), consecutiveLosses));
      }
      Log(StringFormat("Deal indicates LOSS -> consecutiveLosses=%d", consecutiveLosses));
      if(CsvLogging) LogCSV(StringFormat("%s,EVENT,loss_detected,consecutiveLosses=%d", TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS), consecutiveLosses));
   }
   else
   {
      if(consecutiveLosses != 0)
         Log(StringFormat("Deal indicates WIN/BE -> resetting consecutiveLosses %d->0", consecutiveLosses));
      consecutiveLosses = 0;
      reachedDoublingCap = false;
      if(CsvLogging) LogCSV(StringFormat("%s,EVENT,win_reset,consecutiveLosses=0", TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS)));
   }

   // reset states
   referencePrice = Bid();
   waitingForMove = true;
   pendingHistoryCheck = false;
   pendingHistoryAttempts = 0;
   lastPlacedPositionTicket = 0;
   activeTicket = 0;
   positionWasOpen = false;
}

// --------------------------- DEFERRED HISTORY (FALLBACK) -----------------
// Deferred fallback with HistorySelect to encourage history population
void TryProcessPendingHistory()
{
   if(!pendingHistoryCheck) return;

   // attempt to load recent history range first
   datetime from_time = TimeCurrent() - HistorySelectSeconds;
   bool hs = HistorySelect(from_time, TimeCurrent());
   Log(StringFormat("TryProcessPendingHistory: HistorySelect(%s -> %s) returned=%s HistoryDealsTotal=%d",
         TimeToString(from_time, TIME_DATE|TIME_SECONDS),
         TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS),
         hs ? "true":"false", HistoryDealsTotal()));
   if(CsvLogging) LogCSV(StringFormat("%s,DEBUG,HistorySelect,returned=%s,totalDeals=%d", TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS), hs ? "true":"false", HistoryDealsTotal()));

   double totalProfit = 0.0;
   int dealsCount = 0;

   bool found = SumRecentClosingDealsForSymbol(DeferredLookbackDeals, totalProfit, dealsCount);

   if(found)
   {
      Log(StringFormat("Deferred history-check found %d recent non-zero deals totalProfit=%.2f", dealsCount, totalProfit));
      if(totalProfit < 0.0)
      {
         consecutiveLosses++;
         if(consecutiveLosses >= MaxDoublings)
         {
            consecutiveLosses = MaxDoublings;
            reachedDoublingCap = true;
            Log(StringFormat("Deferred: reached cap (%d). reachedDoublingCap set=true", MaxDoublings));
         }
         Log(StringFormat("Deferred result: LOSS -> consecutiveLosses=%d", consecutiveLosses));
         if(CsvLogging) LogCSV(StringFormat("%s,EVENT,deferred_loss,consecutiveLosses=%d,totalProfit=%.5f", TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS), consecutiveLosses, totalProfit));
      }
      else
      {
         if(consecutiveLosses != 0)
            Log(StringFormat("Deferred result: WIN/BE -> resetting consecutiveLosses %d->0", consecutiveLosses));
         consecutiveLosses = 0;
         reachedDoublingCap = false;
         if(CsvLogging) LogCSV(StringFormat("%s,EVENT,deferred_win_reset", TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS)));
      }

      // reset pending state
      pendingHistoryCheck = false;
      pendingHistoryAttempts = 0;
      referencePrice = Bid();
      waitingForMove = true;
      lastPlacedPositionTicket = 0;
      activeTicket = 0;
      positionWasOpen = false;
      return;
   }

   // not found - retry for extended attempts; do NOT assume loss on give-up
   pendingHistoryAttempts++;
   Log(StringFormat("Deferred history-check attempt %d/%d - no recent non-zero deals yet", pendingHistoryAttempts, pendingHistoryMaxAttempts));
   if(CsvLogging) LogCSV(StringFormat("%s,DEBUG,deferred_attempt,%d/%d", TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS), pendingHistoryAttempts, pendingHistoryMaxAttempts));
   if(pendingHistoryAttempts >= pendingHistoryMaxAttempts)
   {
      Log("Deferred history-check giving up -> history not available. No change to consecutiveLosses (conservative).");
      if(CsvLogging) LogCSV(StringFormat("%s,EVENT,deferred_give_up,no_change", TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS)));
      pendingHistoryCheck = false;
      pendingHistoryAttempts = 0;
      referencePrice = Bid();
      waitingForMove = true;
      lastPlacedPositionTicket = 0;
      activeTicket = 0;
      positionWasOpen = false;
   }
}

// --------------------------- RISK / LOTS ---------------------------
double CalcLotsByRisk(double entry, double stopLoss, double riskPercent)
{
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double minLot    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(tickSize <= 0 || tickValue <= 0 || lotStep <= 0 || freeMargin <= 0) return 0.0;

   double riskMoney = (riskPercent/100.0) * freeMargin;
   double slTicks = MathAbs(entry - stopLoss) / tickSize;
   if(slTicks < 0.5) return 0.0;

   double lots = riskMoney / (slTicks * tickValue);
   lots = MathFloor(lots / lotStep) * lotStep;
   if(lots < minLot) return 0.0;
   if(lots > maxLot) lots = maxLot;
   return lots;
}

double CalcLotsWithDoubling(double entry, double stopPrice)
{
   if(FixedLotForTesting > 0.0)
   {
      Log(StringFormat("FixedLotForTesting>0: forcing lots=%.5f", FixedLotForTesting));
      return FixedLotForTesting;
   }

   int doublings = consecutiveLosses;
   if(doublings < 0) doublings = 0;
   if(doublings > MaxDoublings) doublings = MaxDoublings;

   // Ensure LossMultiplier is sensible; do not allow less than 1.0 (would reduce risk)
   double safeMultiplier = LossMultiplier;
   if(safeMultiplier < 1.0) safeMultiplier = 1.0;

   double multiplier = MathPow(safeMultiplier, doublings);
   double effectiveRisk = RiskPercentPerTrade * multiplier;
   double lots = CalcLotsByRisk(entry, stopPrice, effectiveRisk);
   Log(StringFormat("CalcLotsWithDoubling: consecutiveLosses=%d lossMultiplier=%.3f multiplier^n=%.3f effectiveRisk=%.3f%% lots=%.5f",
         consecutiveLosses, safeMultiplier, multiplier, effectiveRisk, lots));
   if(CsvLogging) LogCSV(StringFormat("%s,SIZING,consecutiveLosses=%d,lossMultiplier=%.3f,multiplier=%.5f,effectiveRisk=%.5f,lots=%.5f", TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS), consecutiveLosses, safeMultiplier, multiplier, effectiveRisk, lots));
   return lots;
}

// --------------------------- TRADING -------------------------------
bool PlaceFollowTrade(bool priceMovedUp, datetime triggeredBarTime)
{
   if(PositionSelect(_Symbol))
   {
      Log("Skip entry: position already open.");
      return false;
   }

   double point = PointSize();
   double entryPrice = priceMovedUp ? Ask() : Bid();
   double slPrice = 0.0, tpPrice = 0.0;

   if(priceMovedUp)
   {
      slPrice = entryPrice - StopLossPoints * point;
      tpPrice = entryPrice + TakeProfitPoints * point;
   }
   else
   {
      slPrice = entryPrice + StopLossPoints * point;
      tpPrice = entryPrice - TakeProfitPoints * point;
   }

   // debug: show current consecutiveLosses before sizing
   Log(StringFormat("DEBUG before sizing: consecutiveLosses=%d referencePrice=%.5f entryPrice=%.5f", consecutiveLosses, referencePrice, entryPrice));
   if(CsvLogging) LogCSV(StringFormat("%s,DEBUG,before_sizing,consecutiveLosses=%d,ref=%.5f,entry=%.5f", TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS), consecutiveLosses, referencePrice, entryPrice));

   double lots = CalcLotsWithDoubling(entryPrice, slPrice);
   if(lots <= 0.0)
   {
      Log("Calculated lots <= 0. Not placing trade (insufficient margin or lot < min).");
      if(CsvLogging) LogCSV(StringFormat("%s,EVENT,not_placing,lots=0", TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS)));
      return false;
   }

   string comment = StringFormat("EbbAndFlow|dbl=%d", consecutiveLosses);
   bool res = false;
   if(priceMovedUp)
      res = trade.Buy(lots, _Symbol, 0.0, slPrice, tpPrice, comment);
   else
      res = trade.Sell(lots, _Symbol, 0.0, slPrice, tpPrice, comment);

   if(res)
   {
      if(PositionSelect(_Symbol))
      {
         lastPlacedPositionTicket = (ulong)PositionGetInteger(POSITION_TICKET);
         positionWasOpen = true;
      }
      Log(StringFormat("Order placed. dir=%s lots=%.5f SL=%.5f TP=%.5f posTicket=%I64u comment=%s",
            priceMovedUp ? "BUY":"SELL", lots, slPrice, tpPrice, lastPlacedPositionTicket, comment));
      if(CsvLogging) LogCSV(StringFormat("%s,ORDER,placed,dir=%s,lots=%.5f,sl=%.5f,tp=%.5f,pos=%I64u,dbl=%d", TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS), priceMovedUp ? "BUY":"SELL", lots, slPrice, tpPrice, lastPlacedPositionTicket, consecutiveLosses));

      if(reachedDoublingCap)
      {
         Log(StringFormat("Reached doubling cap was true. Resetting consecutiveLosses (%d -> 0) after placing capped-size trade.", consecutiveLosses));
         if(CsvLogging) LogCSV(StringFormat("%s,EVENT,cap_reset,prevConsecutiveLosses=%d", TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS), consecutiveLosses));
         consecutiveLosses = 0;
         reachedDoublingCap = false;
      }

      return true;
   }
   else
   {
      int err = GetLastError();
      Log(StringFormat("Order send failed, err=%d", err));
      if(CsvLogging) LogCSV(StringFormat("%s,ORDER,send_failed,err=%d", TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS), err));
      referencePrice = (priceMovedUp ? Ask() : Bid());
      waitingForMove = true;
      return false;
   }
}

// --------------------------- INIT -------------------------------
int OnInit()
{
   referencePrice = Bid();
   waitingForMove = true;
   lastClosedBarTime = 0;
   positionWasOpen = PositionSelect(_Symbol);
   lastPlacedPositionTicket = 0;
   consecutiveLosses = 0;
   pendingHistoryCheck = false;
   pendingHistoryAttempts = 0;
   pendingHistoryMaxAttempts = DeferredMaxAttempts; // honor input
   reachedDoublingCap = false;
   Log(StringFormat("OnInit referencePrice=%.5f positionWasOpen=%s pendingHistoryMaxAttempts=%d HistorySelectSeconds=%d LossMultiplier=%.3f",
         referencePrice, positionWasOpen ? "true":"false", pendingHistoryMaxAttempts, HistorySelectSeconds, LossMultiplier));
   if(CsvLogging) LogCSV(StringFormat("%s,INIT,reference=%.5f,pendingMaxAttempts=%d,historySeconds=%d,lossMultiplier=%.3f", TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS), referencePrice, pendingHistoryMaxAttempts, HistorySelectSeconds, LossMultiplier));
   return(INIT_SUCCEEDED);
}

// --------------------------- MAIN -------------------------------
void OnTick()
{
   // 1) If a deferred pending history-check, attempt it first
   TryProcessPendingHistory();

   // 2) copy latest M1 bars, process only on closed bar
   MqlRates rates[];
   int copied = CopyRates(_Symbol, PERIOD_M1, 0, 3, rates);
   if(copied < 2) return;
   datetime closedTime = rates[1].time;
   double closedClose = rates[1].close;

   if(closedTime <= lastClosedBarTime) return;
   lastClosedBarTime = closedTime;

   // If there's a position open, mark that and wait for its close
   if(PositionSelect(_Symbol))
   {
      positionWasOpen = true;
      return;
   }

   // If we detect a transition from position open -> closed but OnTradeTransaction didn't process a deal,
   // perform an immediate history-select and scan for recent non-zero deals BEFORE scheduling deferred retries.
   if(positionWasOpen && !PositionSelect(_Symbol) && !pendingHistoryCheck)
   {
      Log("Position closed detected -> performing immediate history-scan for recent non-zero deals (calling HistorySelect).");
      datetime from_time = TimeCurrent() - HistorySelectSeconds;
      bool hs = HistorySelect(from_time, TimeCurrent());
      Log(StringFormat("Immediate HistorySelect(%s -> %s) returned=%s HistoryDealsTotal=%d",
            TimeToString(from_time, TIME_DATE|TIME_SECONDS),
            TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS),
            hs ? "true":"false", HistoryDealsTotal()));
      if(CsvLogging) LogCSV(StringFormat("%s,DEBUG,ImmediateHistorySelect,returned=%s,totalDeals=%d", TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS), hs ? "true":"false", HistoryDealsTotal()));

      double totalProfit = 0.0;
      int dealsCount = 0;
      bool found = SumRecentClosingDealsForSymbol(DeferredLookbackDeals, totalProfit, dealsCount);
      if(found)
      {
         Log(StringFormat("Immediate fallback-scan found %d recent non-zero deals totalProfit=%.2f", dealsCount, totalProfit));
         if(totalProfit < 0.0)
         {
            consecutiveLosses++;
            if(consecutiveLosses >= MaxDoublings)
            {
               consecutiveLosses = MaxDoublings;
               reachedDoublingCap = true;
               Log(StringFormat("Immediate fallback: reached cap (%d). reachedDoublingCap=true", MaxDoublings));
            }
            Log(StringFormat("Immediate fallback result -> LOSS. consecutiveLosses=%d", consecutiveLosses));
            if(CsvLogging) LogCSV(StringFormat("%s,EVENT,immediate_loss,consecutiveLosses=%d,totalProfit=%.5f", TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS), consecutiveLosses, totalProfit));
         }
         else
         {
            if(consecutiveLosses != 0)
               Log(StringFormat("Immediate fallback result -> WIN/BE. resetting consecutiveLosses %d->0", consecutiveLosses));
            consecutiveLosses = 0;
            reachedDoublingCap = false;
            if(CsvLogging) LogCSV(StringFormat("%s,EVENT,immediate_win_reset", TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS)));
         }

         // reset flags and return to normal flow
         referencePrice = Bid();
         waitingForMove = true;
         positionWasOpen = false;
         lastPlacedPositionTicket = 0;
         activeTicket = 0;
         return;
      }
      else
      {
         // immediate scan didn't find deals -> schedule deferred attempts (extended)
         pendingHistoryCheck = true;
         pendingHistoryAttempts = 0;
         Log(StringFormat("Immediate scan found no recent non-zero deals -> scheduling deferred history-check (pendingHistoryCheck=true). will attempt up to %d times.", pendingHistoryMaxAttempts));
         if(CsvLogging) LogCSV(StringFormat("%s,EVENT,immediate_no_deals,will_attempt=%d", TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS), pendingHistoryMaxAttempts));
         // keep positionWasOpen true so deferred logic knows we recently had a position
         return;
      }
   }

   // waiting for move
   if(waitingForMove)
   {
      double diffPoints = MathAbs(closedClose - referencePrice) / PointSize();
      if(diffPoints >= MovePoints)
      {
         bool movedUp = (closedClose > referencePrice);
         Log(StringFormat("Detected move: reference=%.5f closedClose=%.5f diffPoints=%.0f movedUp=%s",
               referencePrice, closedClose, diffPoints, movedUp ? "true":"false"));

         bool ok = PlaceFollowTrade(movedUp, closedTime);
         if(ok) waitingForMove = false;
         else
         {
            referencePrice = closedClose;
            Log("Entry failed; reference reset to closedClose.");
         }
      }
   }
   else
   {
      // safety: if no position and not waiting, reset reference
      waitingForMove = true;
      referencePrice = closedClose;
      Log("No active position; reference reset to closedClose.");
   }
}
//+------------------------------------------------------------------+