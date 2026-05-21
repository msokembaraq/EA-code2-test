//+------------------------------------------------------------------+
//|                    StochRSI_MTF_Alert.mq5                        |
//|    Stochastic K/D Cross with K-Level Zone Filter + Price Pivots  |
//|    Dual-TF State Machine – both TFs must agree, no expiry        |
//|    v4.30 – price-based pivots for BUY/SELL AGAIN                 |
//|                                                                  |
//|  SIGNAL LOGIC:                                                   |
//|   BUY        – K crosses D UP   while K <= OS level              |
//|   SELL       – K crosses D DOWN while K >= OB level              |
//|   BUY AGAIN  – K crosses D UP   in BuyAgain zone                 |
//|                AND close > last BUY close + MinPriceGap          |
//|                AND MA sloping UP                                  |
//|   SELL AGAIN – K crosses D DOWN in SellAgain zone                |
//|                AND close < last SELL close - MinPriceGap         |
//|                AND MA sloping DOWN                               |
//|                                                                  |
//|  CONFIRMATION: alert fires only when TF1 AND TF2 hold the same  |
//|  state. No expiry – states persist until overwritten.            |
//+------------------------------------------------------------------+
#property copyright   "Custom Indicator"
#property version     "4.30"
#property description "Stoch K/D cross with price-pivot re-entries – dual-TF state machine"
#property indicator_chart_window
#property indicator_plots 0

//════════════════════════════════════════════════════════════════════
//  INPUT PARAMETERS
//════════════════════════════════════════════════════════════════════
input group "══════ Stochastic Settings – TF1 ══════"
input int    InpStoch_K    = 50;    // TF1 %K Period
input int    InpStoch_D    = 7;     // TF1 %D Period (signal)
input int    InpStoch_Slow = 11;    // TF1 Slowing

input group "══════ Stochastic Settings – TF2 Override ══════"
input bool   InpTF2UseOwnStoch = false; // Use different Stoch params for TF2
input int    InpStoch_K2    = 30;   // TF2 %K Period
input int    InpStoch_D2    = 5;    // TF2 %D Period (signal)
input int    InpStoch_Slow2 = 7;    // TF2 Slowing

input group "══════ OB / OS Levels ══════"
input double InpOB_Level   = 80.0;  // Overbought – K above this → SELL zone
input double InpOS_Level   = 20.0;  // Oversold   – K below this → BUY zone

input group "══════ Re-Entry Zone Filters (K level) ══════"
input double InpSellAgain_High = 75.0;  // Sell-Again K upper
input double InpSellAgain_Low  = 65.0;  // Sell-Again K lower
input double InpBuyAgain_High  = 35.0;  // Buy-Again K upper
input double InpBuyAgain_Low   = 25.0;  // Buy-Again K lower

input group "══════ Re-Entry Filters ══════"
input double InpMinPriceGap      = 500;  // Min price gap in points (e.g. 500 = $5 on XAUUSD)
input int    InpSignalCooldownMin = 60;  // Min minutes between same-type signals (0 = off)

input group "══════ MA Trend Filter (re-entries only) ══════"
input bool           InpEnableMAFilter = true;     // Require MA slope agreement for re-entries
input int            InpMA_Period      = 200;      // TF1 MA period
input ENUM_MA_METHOD InpMA_Method      = MODE_SMA; // MA method
input bool           InpTF2UseOwnMA    = false;    // Use different MA period for TF2
input int            InpMA_Period2     = 100;      // TF2 MA period

input group "══════ Timeframe Selection ══════"
input ENUM_TIMEFRAMES InpTF1       = PERIOD_H1;  // Timeframe 1
input bool            InpEnableTF1 = true;        // Enable TF1
input ENUM_TIMEFRAMES InpTF2       = PERIOD_H4;  // Timeframe 2
input bool            InpEnableTF2 = true;        // Enable TF2

input group "══════ Notification Settings ══════"
input bool InpEnablePush   = true;   // Send Push Notification
input bool InpEnablePopup  = false;  // Show Alert Popup
input bool InpEnablePrint  = true;   // Print to Journal

//════════════════════════════════════════════════════════════════════
//  SIGNAL TYPE CONSTANTS
//════════════════════════════════════════════════════════════════════
#define SIG_NONE       0
#define SIG_BUY        1
#define SIG_SELL       2
#define SIG_BUY_AGAIN  3
#define SIG_SELL_AGAIN 4

//════════════════════════════════════════════════════════════════════
//  GLOBALS
//════════════════════════════════════════════════════════════════════

// Indicator handles
int g_h_stoch_1 = INVALID_HANDLE;
int g_h_stoch_2 = INVALID_HANDLE;
int g_h_ma_1    = INVALID_HANDLE;
int g_h_ma_2    = INVALID_HANDLE;

// Last processed bar timestamps
datetime g_lastBar_1 = 0;
datetime g_lastBar_2 = 0;

// Price at last primary signal — used for BUY AGAIN / SELL AGAIN pivot check
double g_lastBuyPrice_1  = -1.0;   // close price at last BUY on TF1
double g_lastSellPrice_1 = -1.0;   // close price at last SELL on TF1
double g_lastBuyPrice_2  = -1.0;
double g_lastSellPrice_2 = -1.0;

// TF state (persists until a new signal overwrites it)
int      g_state_1 = SIG_NONE;
datetime g_bar_1   = 0;

int      g_state_2 = SIG_NONE;
datetime g_bar_2   = 0;

// Bar pair at last confirmed fire – prevents re-firing same agreement
datetime g_fired_bar_1 = 0;
datetime g_fired_bar_2 = 0;

// Cooldown – last confirmed signal type and time
int      g_lastCooldownSig  = SIG_NONE;
datetime g_lastCooldownTime = 0;

//+------------------------------------------------------------------+
//  INIT
//+------------------------------------------------------------------+
int OnInit()
{
   g_lastBar_1 = g_lastBar_2 = 0;
   g_lastBuyPrice_1 = g_lastSellPrice_1 = -1.0;
   g_lastBuyPrice_2 = g_lastSellPrice_2 = -1.0;
   g_state_1 = g_state_2 = SIG_NONE;
   g_bar_1   = g_bar_2   = 0;
   g_fired_bar_1 = g_fired_bar_2 = 0;
   g_lastCooldownSig  = SIG_NONE;
   g_lastCooldownTime = 0;

   int tf2K    = InpTF2UseOwnStoch ? InpStoch_K2    : InpStoch_K;
   int tf2D    = InpTF2UseOwnStoch ? InpStoch_D2    : InpStoch_D;
   int tf2Slow = InpTF2UseOwnStoch ? InpStoch_Slow2 : InpStoch_Slow;

   g_h_stoch_1 = iStochastic(_Symbol, InpTF1, InpStoch_K, InpStoch_D, InpStoch_Slow, MODE_SMA, STO_LOWHIGH);
   g_h_stoch_2 = iStochastic(_Symbol, InpTF2, tf2K,       tf2D,       tf2Slow,       MODE_SMA, STO_LOWHIGH);

   if(g_h_stoch_1 == INVALID_HANDLE){ Alert("StochRSI: Failed Stoch TF1 handle"); return INIT_FAILED; }
   if(g_h_stoch_2 == INVALID_HANDLE){ Alert("StochRSI: Failed Stoch TF2 handle"); return INIT_FAILED; }

   if(InpEnableMAFilter)
   {
      int tf2MAPeriod = InpTF2UseOwnMA ? InpMA_Period2 : InpMA_Period;
      g_h_ma_1 = iMA(_Symbol, InpTF1, InpMA_Period, 0, InpMA_Method, PRICE_CLOSE);
      g_h_ma_2 = iMA(_Symbol, InpTF2, tf2MAPeriod,  0, InpMA_Method, PRICE_CLOSE);
      if(g_h_ma_1 == INVALID_HANDLE){ Alert("StochRSI: Failed MA TF1 handle"); return INIT_FAILED; }
      if(g_h_ma_2 == INVALID_HANDLE){ Alert("StochRSI: Failed MA TF2 handle"); return INIT_FAILED; }
   }

   EventSetTimer(2);

   int tf2MAPeriodLog = InpTF2UseOwnMA ? InpMA_Period2 : InpMA_Period;
   Print("StochRSI v4.30 loaded  ", _Symbol,
         " | TF1:", TFName(InpTF1),
         " Stoch(", InpStoch_K, ",", InpStoch_D, ",", InpStoch_Slow, ")",
         " MA(", InpMA_Period, ")",
         " | TF2:", TFName(InpTF2),
         " Stoch(", tf2K, ",", tf2D, ",", tf2Slow, ")",
         " MA(", tf2MAPeriodLog, ")",
         " | MAfilter:", (InpEnableMAFilter ? "ON" : "OFF"),
         " | OB:", InpOB_Level, " OS:", InpOS_Level,
         " | Cooldown:", InpSignalCooldownMin, "min",
         " | PriceGap:", InpMinPriceGap, "pts (=",
         DoubleToString(InpMinPriceGap * _Point, _Digits), ")");

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//  DEINIT
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   if(g_h_stoch_1 != INVALID_HANDLE) IndicatorRelease(g_h_stoch_1);
   if(g_h_stoch_2 != INVALID_HANDLE) IndicatorRelease(g_h_stoch_2);
   if(g_h_ma_1    != INVALID_HANDLE) IndicatorRelease(g_h_ma_1);
   if(g_h_ma_2    != INVALID_HANDLE) IndicatorRelease(g_h_ma_2);
}

//+------------------------------------------------------------------+
//  TIMER / ONCALCULATE
//+------------------------------------------------------------------+
void OnTimer() { CheckAllTimeframes(); }

int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double   &open[],
                const double   &high[],
                const double   &low[],
                const double   &close[],
                const long     &tick_volume[],
                const long     &volume[],
                const int      &spread[])
{
   CheckAllTimeframes();
   return rates_total;
}

//+------------------------------------------------------------------+
//  CheckAllTimeframes
//+------------------------------------------------------------------+
void CheckAllTimeframes()
{
   bool changed1 = false;
   bool changed2 = false;

   if(InpEnableTF1)
      changed1 = ProcessTimeframe(InpTF1, g_h_stoch_1, g_h_ma_1,
                                  g_lastBar_1,
                                  g_lastBuyPrice_1, g_lastSellPrice_1,
                                  g_state_1, g_bar_1);

   if(InpEnableTF2)
      changed2 = ProcessTimeframe(InpTF2, g_h_stoch_2, g_h_ma_2,
                                  g_lastBar_2,
                                  g_lastBuyPrice_2, g_lastSellPrice_2,
                                  g_state_2, g_bar_2);

   if(changed1 || changed2)
      CheckConfirmation();
}

//+------------------------------------------------------------------+
//  PassesCooldown
//+------------------------------------------------------------------+
bool PassesCooldown(int sigType, datetime t)
{
   if(InpSignalCooldownMin <= 0)    return true;
   if(g_lastCooldownSig != sigType) return true;
   return (t - g_lastCooldownTime) >= (datetime)(InpSignalCooldownMin * 60);
}

//+------------------------------------------------------------------+
//  ProcessTimeframe
//  Returns true if state changed.
//+------------------------------------------------------------------+
bool ProcessTimeframe(ENUM_TIMEFRAMES  tf,
                      int              h_stoch,
                      int              h_ma,
                      datetime        &lastBar,
                      double          &lastBuyPrice,
                      double          &lastSellPrice,
                      int             &state,
                      datetime        &stateBar)
{
   datetime barTimes[3];
   if(CopyTime(_Symbol, tf, 0, 3, barTimes) < 3) return false;
   if(barTimes[1] == lastBar)                     return false;
   lastBar = barTimes[1];

   double k_buf[3], d_buf[3];
   if(CopyBuffer(h_stoch, MAIN_LINE,   0, 3, k_buf) < 3) return false;
   if(CopyBuffer(h_stoch, SIGNAL_LINE, 0, 3, d_buf) < 3) return false;

   double k1 = k_buf[1];
   double d1 = d_buf[1];
   double k2 = k_buf[2];
   double d2 = d_buf[2];

   bool crossedUp   = (k2 <= d2) && (k1 > d1);
   bool crossedDown = (k2 >= d2) && (k1 < d1);
   if(!crossedUp && !crossedDown) return false;

   double barO = iOpen (_Symbol, tf, 1);
   double barH = iHigh (_Symbol, tf, 1);
   double barL = iLow  (_Symbol, tf, 1);
   double barC = iClose(_Symbol, tf, 1);
   double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   Print("[CROSS ", TFName(tf), " ", TimeToString(barTimes[1], TIME_DATE|TIME_MINUTES), "]",
         "  ", (crossedUp ? "UP" : "DN"),
         "  K=",    DoubleToString(k1, 2), " D=",    DoubleToString(d1, 2),
         "  prevK=",DoubleToString(k2, 2), " prevD=",DoubleToString(d2, 2),
         "  | O:", DoubleToString(barO, _Digits),
         " H:", DoubleToString(barH, _Digits),
         " L:", DoubleToString(barL, _Digits),
         " C:", DoubleToString(barC, _Digits),
         "  | Bid:", DoubleToString(bid, _Digits));

   //--- ══ MA slope for trend filter ════════════════════════════════
   bool maUptrend   = true;
   bool maDowntrend = true;
   if(InpEnableMAFilter && h_ma != INVALID_HANDLE)
   {
      double ma_buf[3];
      if(CopyBuffer(h_ma, 0, 0, 3, ma_buf) >= 3)
      {
         maUptrend   = (ma_buf[1] > ma_buf[2]);
         maDowntrend = (ma_buf[1] < ma_buf[2]);
      }
   }

   //--- ══ PRIMARY BUY ══════════════════════════════════════════════
   if(crossedUp && k1 <= InpOS_Level)
   {
      lastBuyPrice = barC;
      state        = SIG_BUY;
      stateBar     = barTimes[1];
      Print("[STATE ", TFName(tf), "] → BUY  (K=", DoubleToString(k1,2),
            " <= OS:", InpOS_Level, " | buyPrice=", DoubleToString(barC, _Digits), ")");
      return true;
   }

   //--- ══ PRIMARY SELL ══════════════════════════════════════════════
   if(crossedDown && k1 >= InpOB_Level)
   {
      lastSellPrice = barC;
      state         = SIG_SELL;
      stateBar      = barTimes[1];
      Print("[STATE ", TFName(tf), "] → SELL  (K=", DoubleToString(k1,2),
            " >= OB:", InpOB_Level, " | sellPrice=", DoubleToString(barC, _Digits), ")");
      return true;
   }

   //--- ══ SELL AGAIN ════════════════════════════════════════════════
   //    K crosses D down in zone (65–75)
   //    Close must be LOWER than last SELL close by MinPriceGap (lower low in price)
   //    MA must slope DOWN
   if(crossedDown && k1 >= InpSellAgain_Low && k1 <= InpSellAgain_High)
   {
      if(!maDowntrend)
      {
         Print("[REJECT ", TFName(tf), "] SELL AGAIN – MA not sloping down  (K=", DoubleToString(k1,2), ")");
         return false;
      }
      if(lastSellPrice < 0.0)
      {
         Print("[REJECT ", TFName(tf), "] SELL AGAIN – no prior SELL price established");
         return false;
      }
      double minPrice = lastSellPrice - InpMinPriceGap * _Point;
      if(barC < minPrice)
      {
         double oldPrice  = lastSellPrice;
         lastSellPrice    = barC;
         state            = SIG_SELL_AGAIN;
         stateBar         = barTimes[1];
         Print("[STATE ", TFName(tf), "] → SELL AGAIN",
               "  K=", DoubleToString(k1,2),
               "  C=", DoubleToString(barC, _Digits),
               " < prev SELL:", DoubleToString(oldPrice, _Digits),
               " - gap:", DoubleToString(InpMinPriceGap * _Point, _Digits),
               " → new sellPrice=", DoubleToString(barC, _Digits));
         return true;
      }
      Print("[REJECT ", TFName(tf), "] SELL AGAIN – price not lower low",
            "  C=", DoubleToString(barC, _Digits),
            " lastSellPrice=", DoubleToString(lastSellPrice, _Digits),
            " need < ", DoubleToString(minPrice, _Digits));
      return false;
   }

   //--- ══ BUY AGAIN ═════════════════════════════════════════════════
   //    K crosses D up in zone (25–35)
   //    Close must be HIGHER than last BUY close by MinPriceGap (higher high in price)
   //    MA must slope UP
   if(crossedUp && k1 >= InpBuyAgain_Low && k1 <= InpBuyAgain_High)
   {
      if(!maUptrend)
      {
         Print("[REJECT ", TFName(tf), "] BUY AGAIN – MA not sloping up  (K=", DoubleToString(k1,2), ")");
         return false;
      }
      if(lastBuyPrice < 0.0)
      {
         Print("[REJECT ", TFName(tf), "] BUY AGAIN – no prior BUY price established");
         return false;
      }
      double minPrice = lastBuyPrice + InpMinPriceGap * _Point;
      if(barC > minPrice)
      {
         double oldPrice = lastBuyPrice;
         lastBuyPrice    = barC;
         state           = SIG_BUY_AGAIN;
         stateBar        = barTimes[1];
         Print("[STATE ", TFName(tf), "] → BUY AGAIN",
               "  K=", DoubleToString(k1,2),
               "  C=", DoubleToString(barC, _Digits),
               " > prev BUY:", DoubleToString(oldPrice, _Digits),
               " + gap:", DoubleToString(InpMinPriceGap * _Point, _Digits),
               " → new buyPrice=", DoubleToString(barC, _Digits));
         return true;
      }
      Print("[REJECT ", TFName(tf), "] BUY AGAIN – price not higher high",
            "  C=", DoubleToString(barC, _Digits),
            " lastBuyPrice=", DoubleToString(lastBuyPrice, _Digits),
            " need > ", DoubleToString(minPrice, _Digits));
      return false;
   }

   Print("[REJECT ", TFName(tf), "] Cross ", (crossedUp?"UP":"DN"),
         " K=", DoubleToString(k1,2), " – no zone matched");
   return false;
}

//+------------------------------------------------------------------+
//  CheckConfirmation
//+------------------------------------------------------------------+
void CheckConfirmation()
{
   if(!InpEnableTF1 || !InpEnableTF2)
   {
      if(InpEnableTF1 && g_state_1 != SIG_NONE && g_bar_1 != g_fired_bar_1)
      {
         if(PassesCooldown(g_state_1, g_bar_1))
         {
            FireAlert(SignalTypeName(g_state_1) + " " + _Symbol);
            g_fired_bar_1      = g_bar_1;
            g_lastCooldownSig  = g_state_1;
            g_lastCooldownTime = g_bar_1;
         }
         else
            Print("[COOLDOWN] ", SignalTypeName(g_state_1), " blocked (TF1)");
      }
      if(InpEnableTF2 && g_state_2 != SIG_NONE && g_bar_2 != g_fired_bar_2)
      {
         if(PassesCooldown(g_state_2, g_bar_2))
         {
            FireAlert(SignalTypeName(g_state_2) + " " + _Symbol);
            g_fired_bar_2      = g_bar_2;
            g_lastCooldownSig  = g_state_2;
            g_lastCooldownTime = g_bar_2;
         }
         else
            Print("[COOLDOWN] ", SignalTypeName(g_state_2), " blocked (TF2)");
      }
      return;
   }

   if(g_state_1 == SIG_NONE || g_state_2 == SIG_NONE)       return;
   if(g_state_1 != g_state_2)                                return;
   if(g_bar_1 == g_fired_bar_1 && g_bar_2 == g_fired_bar_2) return;

   datetime confirmedTime = MathMax(g_bar_1, g_bar_2);
   if(!PassesCooldown(g_state_1, confirmedTime))
   {
      Print("[COOLDOWN] ", SignalTypeName(g_state_1), " blocked – within ", InpSignalCooldownMin, "min");
      g_fired_bar_1 = g_bar_1;
      g_fired_bar_2 = g_bar_2;
      return;
   }

   FireAlert(SignalTypeName(g_state_1) + " " + _Symbol);

   g_fired_bar_1      = g_bar_1;
   g_fired_bar_2      = g_bar_2;
   g_lastCooldownSig  = g_state_1;
   g_lastCooldownTime = confirmedTime;
}

//+------------------------------------------------------------------+
//  SignalTypeName
//+------------------------------------------------------------------+
string SignalTypeName(int sigType)
{
   switch(sigType)
   {
      case SIG_BUY:        return "BUY";
      case SIG_SELL:       return "SELL";
      case SIG_BUY_AGAIN:  return "BUY AGAIN";
      case SIG_SELL_AGAIN: return "SELL AGAIN";
   }
   return "–";
}

//+------------------------------------------------------------------+
//  TFName
//+------------------------------------------------------------------+
string TFName(ENUM_TIMEFRAMES tf)
{
   string s = EnumToString(tf);
   StringReplace(s, "PERIOD_", "");
   return s;
}

//+------------------------------------------------------------------+
//  FireAlert
//+------------------------------------------------------------------+
void FireAlert(string msg)
{
   string bid     = DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_BID), _Digits);
   string ask     = DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_ASK), _Digits);
   string fullMsg = msg + "  Bid:" + bid + " Ask:" + ask;

   if(InpEnablePush && !SendNotification(fullMsg))
      Print("Push failed. Ensure mobile terminal is linked.");

   if(InpEnablePopup)
      Alert(fullMsg);

   if(InpEnablePrint)
      Print("*** SIGNAL *** ", fullMsg);
}

//+------------------------------------------------------------------+
//  END OF FILE
//+------------------------------------------------------------------+
