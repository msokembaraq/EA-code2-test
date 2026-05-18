//+------------------------------------------------------------------+
//|                                               PyramidUtils.mqh  |
//|                                    Infrastructure / helpers only |
//+------------------------------------------------------------------+
#property copyright "bidiisStrategy"
#property version   "1.00"

//+------------------------------------------------------------------+
//| Pip size in price units (handles 3/5-digit brokers)              |
//+------------------------------------------------------------------+
double GetPipSize(string symbol)
{
    int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
    double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
    if(digits == 3 || digits == 5)
        return point * 10.0;
    return point;
}

//+------------------------------------------------------------------+
//| Monetary value of one pip for a given lot size                   |
//+------------------------------------------------------------------+
double GetPipValue(string symbol, double lot_size)
{
    double pip_size   = GetPipSize(symbol);
    double tick_value = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
    double tick_size  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
    if(tick_size <= 0.0) return 0.0;
    return (pip_size / tick_size) * tick_value * lot_size;
}

//+------------------------------------------------------------------+
//| Returns true if the stop is at least the broker minimum away     |
//+------------------------------------------------------------------+
bool IsStopLevelValid(string symbol, double sl_price, ENUM_ORDER_TYPE order_type)
{
    double ask       = SymbolInfoDouble(symbol, SYMBOL_ASK);
    double bid       = SymbolInfoDouble(symbol, SYMBOL_BID);
    int    stop_lvl  = (int)SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
    double point     = SymbolInfoDouble(symbol, SYMBOL_POINT);
    double min_dist  = stop_lvl * point;

    if(order_type == ORDER_TYPE_BUY)
        return (ask - sl_price) >= min_dist;
    return (sl_price - bid) >= min_dist;
}

//+------------------------------------------------------------------+
//| Returns true if the position is outside the broker freeze zone   |
//+------------------------------------------------------------------+
bool IsModificationAllowed(string symbol, ulong ticket)
{
    if(!PositionSelectByTicket(ticket)) return false;
    long   pos_type    = PositionGetInteger(POSITION_TYPE);
    double current     = (pos_type == POSITION_TYPE_BUY)
                         ? SymbolInfoDouble(symbol, SYMBOL_BID)
                         : SymbolInfoDouble(symbol, SYMBOL_ASK);
    double open_price  = PositionGetDouble(POSITION_PRICE_OPEN);
    int    freeze_lvl  = (int)SymbolInfoInteger(symbol, SYMBOL_TRADE_FREEZE_LEVEL);
    double point       = SymbolInfoDouble(symbol, SYMBOL_POINT);
    if(freeze_lvl == 0) return true;
    return MathAbs(current - open_price) > freeze_lvl * point;
}

//+------------------------------------------------------------------+
//| Returns true when account is retail hedging                      |
//+------------------------------------------------------------------+
bool IsHedgingAccount()
{
    return ((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE)
            == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);
}

//+------------------------------------------------------------------+
//| ATR-based volatility filter                                      |
//+------------------------------------------------------------------+
bool IsVolatilityAcceptable(string symbol, ENUM_TIMEFRAMES tf,
                            int atr_period, double min_pips, double max_pips)
{
    int handle = iATR(symbol, tf, atr_period);
    if(handle == INVALID_HANDLE) return false;

    double atr_buf[];
    ArraySetAsSeries(atr_buf, true);
    bool ok = CopyBuffer(handle, 0, 0, 1, atr_buf) > 0;
    IndicatorRelease(handle);
    if(!ok) return false;

    double pip_size = GetPipSize(symbol);
    if(pip_size <= 0.0) return false;

    double atr_pips = atr_buf[0] / pip_size;
    return (atr_pips >= min_pips && atr_pips <= max_pips);
}
