# ATR-Based Trailing Stop Implementation for WaveCrestEA

## Overview
This document describes the ATR-based trailing stop mechanism added to WaveCrestEA v1.88.

## New Input Parameters

### ATR_TrailingStop_Enabled (default: true)
- **Type:** Boolean
- **Purpose:** Enable or disable the trailing stop mechanism
- **Usage:** Set to `false` to disable trailing stop and use only fixed SL/TP

### ATR_ProfitThreshold_Multiplier (default: 1.0)
- **Type:** Double
- **Purpose:** Defines the minimum profit (as a multiple of ATR) required before the trailing stop mechanism activates
- **Example:** If ATR = 0.0010 and multiplier = 1.0, the position must be in profit by at least 0.0010 before trailing begins
- **Recommendation:** Use 1.0-2.0 for typical trading. Lower values activate trailing sooner.

## How It Works

### 1. Initial Stop Loss (Unchanged)
When a trade is opened, the initial stop loss is set at:
- **Buy:** Entry Price - (ATR × ATR_Multiplier)
- **Sell:** Entry Price + (ATR × ATR_Multiplier)

Example with ATR = 0.0010 and ATR_Multiplier = 1.5:
- Buy at 1.1000 → Initial SL = 1.0985
- Sell at 1.1000 → Initial SL = 1.1015

### 2. Profit Threshold
The trailing stop mechanism does NOT activate until the position reaches a profit threshold:
- **Profit Threshold = ATR × ATR_ProfitThreshold_Multiplier**

Example with ATR = 0.0010 and ATR_ProfitThreshold_Multiplier = 1.0:
- Profit threshold = 0.0010
- Buy position must reach at least 1.1010 (profit ≥ 0.0010) before trailing activates
- Sell position must reach at most 1.0990 (profit ≥ 0.0010) before trailing activates

### 3. Trailing Stop Activation
When profit threshold is met at candle close:
1. Trailing stop is marked as active
2. The stop loss is immediately moved to ATR distance from the current candle's low (buy) or high (sell)
3. The system logs: "Trailing stop ACTIVATED and set to X.XXXX"

### 4. Higher Lows (Buy) / Lower Highs (Sell)
After activation, the trailing stop adjusts ONLY at candle close when:

**For Buy Positions:**
- A new **higher low** is detected (current candle low > previous tracked low)
- New SL = New Higher Low - (ATR × ATR_Multiplier)
- SL only moves UP (never down)

**For Sell Positions:**
- A new **lower high** is detected (current candle high < previous tracked high)
- New SL = New Lower High + (ATR × ATR_Multiplier)
- SL only moves DOWN (never up)

### 5. Stop Loss Locking
- Once the trailing stop moves in the direction of profit, it NEVER moves backward
- If price retraces, the stop loss remains at its best position
- Only a new higher low (buy) or lower high (sell) will move the SL further

### 6. Update Frequency
- ALL trailing stop adjustments occur ONLY at candle close
- No intra-candle updates
- Each candle is processed exactly once using `lastProcessedCandleForTrailing`

## Example Trade Scenario

### Buy Trade Example
**Assumptions:**
- ATR = 0.0010
- ATR_Multiplier = 1.5 (for SL distance)
- ATR_ProfitThreshold_Multiplier = 1.0
- Initial Entry = 1.1000

**Trade Flow:**
1. **Entry:** Buy at 1.1000, Initial SL = 1.0985
2. **Candle 1:** Close = 1.1005, Low = 1.0995
   - Profit = 0.0005 < 0.0010 (threshold) → No trailing yet
3. **Candle 2:** Close = 1.1012, Low = 1.1008
   - Profit = 0.0012 ≥ 0.0010 → **Trailing Activates!**
   - New SL = 1.1008 - 0.0015 = 1.0993 (moved from 1.0985 to 1.0993) ✓
4. **Candle 3:** Close = 1.1020, Low = 1.1015
   - Higher low detected: 1.1015 > 1.1008
   - New SL = 1.1015 - 0.0015 = 1.1000 (moved from 1.0993 to 1.1000) ✓
5. **Candle 4:** Close = 1.1018, Low = 1.1012
   - Lower low: 1.1012 < 1.1015 → No adjustment (SL stays at 1.1000)
6. **Candle 5:** Close = 1.1030, Low = 1.1025
   - Higher low detected: 1.1025 > 1.1015
   - New SL = 1.1025 - 0.0015 = 1.1010 (moved from 1.1000 to 1.1010) ✓

### Sell Trade Example
**Assumptions:**
- ATR = 0.0010
- ATR_Multiplier = 1.5
- ATR_ProfitThreshold_Multiplier = 1.0
- Initial Entry = 1.1000

**Trade Flow:**
1. **Entry:** Sell at 1.1000, Initial SL = 1.1015
2. **Candle 1:** Close = 1.0995, High = 1.1005
   - Profit = 0.0005 < 0.0010 → No trailing yet
3. **Candle 2:** Close = 1.0987, High = 1.0992
   - Profit = 0.0013 ≥ 0.0010 → **Trailing Activates!**
   - New SL = 1.0992 + 0.0015 = 1.1007 (moved from 1.1015 to 1.1007) ✓
4. **Candle 3:** Close = 1.0980, High = 1.0985
   - Lower high detected: 1.0985 < 1.0992
   - New SL = 1.0985 + 0.0015 = 1.1000 (moved from 1.1007 to 1.1000) ✓
5. **Candle 4:** Close = 1.0988, High = 1.0993
   - Higher high: 1.0993 > 1.0985 → No adjustment (SL stays at 1.1000)
6. **Candle 5:** Close = 1.0975, High = 1.0980
   - Lower high detected: 1.0980 < 1.0985
   - New SL = 1.0980 + 0.0015 = 1.0995 (moved from 1.1000 to 1.0995) ✓

## Diagnostic Logging

When `PrintTradeInfo = true`, the EA logs trailing stop events:

```
WaveCrestEA: Trailing stop ACTIVATED and set to 1.09930. Profit=0.00120 >= Threshold=0.00100
WaveCrestEA: BUY - New higher low=1.10150, New SL=1.10000 (Old SL=1.09930)
WaveCrestEA: Trailing stop UPDATED to 1.10000
```

## Configuration Recommendations

### Conservative (Long-term trades)
- ATR_ProfitThreshold_Multiplier = 2.0
- Allows more room before trailing begins

### Balanced (Default)
- ATR_ProfitThreshold_Multiplier = 1.0
- Good balance between protection and flexibility

### Aggressive (Quick profit locking)
- ATR_ProfitThreshold_Multiplier = 0.5
- Trailing begins sooner but may exit prematurely

## Testing

To test the trailing stop:
1. Enable `PrintTradeInfo = true`
2. Use `FixedLotForTesting > 0` for consistent lot sizing
3. Monitor the Expert logs for trailing stop messages
4. Verify that SL only moves in profit direction
5. Confirm updates occur only at candle close

## Compatibility

- Works with all existing WaveCrestEA features
- Can be disabled with `ATR_TrailingStop_Enabled = false`
- Uses the same ATR_Period and ATR_Multiplier as the initial stop loss
- Does not interfere with take profit (TP) levels

## Technical Notes

- State is tracked per-symbol using global variables
- When position closes, all trailing stop state is reset
- The mechanism uses `lastProcessedCandleForTrailing` to ensure exactly one update per candle
- Uses `PositionModify()` to update the stop loss without affecting take profit
