//+------------------------------------------------------------------+
//|                    StochRSI_MTF_Alert.mq5                        |
//|    Stochastic K/D Cross with K-Level Zone Filter + Price Pivots  |
//|    Dual-TF State Machine – TF1 signals, TF2 confirms direction   |
//|    v4.34 – EMA cross independent secondary signal                |
//|                                                                  |
//|  SIGNAL LOGIC (TF1 – strict):                                    |
//|   BUY        – K crosses D UP   AND K touched OS within N bars   |
//|   SELL       – K crosses D DOWN AND K touched OB within N bars   |
//|   BUY AGAIN  – K crosses D UP   in BuyAgain zone (25-35)        |
//|                AND close > last BUY close + MinPriceGap          |
//|                AND MA sloping UP                                  |
//|   SELL AGAIN – K crosses D DOWN in SellAgain zone (65-75)       |
//|                AND close < last SELL close - MinPriceGap         |
//|                AND MA sloping DOWN                               |
//|                                                                  |
//|  STAGE 1: TF1 arms → push "BUY/SELL READY (RISKY)"             |
//|  STAGE 2: TF2 confirms → push "BUY/SELL NOW (SAFE)"            |
//|           with TP1 / TP2 / TP3 and SL at recent swing           |
//|  EMA CROSS: fast EMA crosses slow EMA → independent push        |
//+------------------------------------------------------------------+
#property copyright   "Custom Indicator"
#property version     "4.34"
#property description "Stoch K/D cross + EMA cross – dual independent signal streams"
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
input int    InpStoch_K2    = 24;   // TF2 %K Period
input int    InpStoch_D2    = 3;    // TF2 %D Period (signal)
input int    InpStoch_Slow2 = 9;    // TF2 Slowing

input group "══════ OB / OS Levels ══════"
input double InpOB_Level   = 80.0;  // Overbought – K above this → SELL zone
input double InpOS_Level   = 20.0;  // Oversold   – K below this → BUY zone
input int    InpOSLookback = 20;     // Bars to look back for recent OB/OS touch

input group "══════ Re-Entry Zone Filters (K level) ══════"
input double InpSellAgain_High = 75.0;  // Sell-Again K upper
input double InpSellAgain_Low  = 65.0;  // Sell-Again K lower
input double InpBuyAgain_High  = 35.0;  // Buy-Again K upper
input double InpBuyAgain_Low   = 25.0;  // Buy-Again K lower

input group "══════ Re-Entry Filters ══════"
input double InpMinPriceGap      = 500;  // Min price gap in points (e.g. 500 = $5 on XAUUSD)
input int    InpSignalCooldownMin = 60;  // Min minutes between same-type signals (0 = off)

input group "══════ EMA Settings ══════"
input int            InpMA_Period      = 34;       // Slow EMA period
input int            InpMA_Period2     = 16;       // Fast EMA period
input ENUM_MA_METHOD InpMA_Method      = MODE_EMA; // MA method

input group "══════ EMA Cross Signal (independent) ══════"
input bool            InpEMACrossEnable = true;       // Enable EMA cross secondary signal
input ENUM_TIMEFRAMES InpEMACross_TF    = PERIOD_M5;  // TF for both EMAs (same TF cross)

input group "══════ MA Slope Filter (re-entries only) ══════"
input bool           InpEnableMAFilter = true;     // Require slow EMA slope for re-entries

input group "══════ Timeframe Selection ══════"
input ENUM_TIMEFRAMES InpTF1            = PERIOD_M5;  // Timeframe 1 (signal source – strict zones)
input bool            InpEnableTF1      = true;        // Enable TF1
input ENUM_TIMEFRAMES InpTF2            = PERIOD_M15;  // Timeframe 2 (confirmation)
input bool            InpEnableTF2      = true;        // Enable TF2
input bool            InpTF2StrictZones = false;       // TF2 strict (false = any cross confirms direction)

input group "══════ TP / SL Targets ══════"
input int    InpSLLookback = 20;    // Bars back to find swing SL (on TF1)
input double InpTP1_RR     = 1.0;   // TP1 Risk:Reward ratio
input double InpTP2_RR     = 2.0;   // TP2 Risk:Reward ratio
input double InpTP3_RR     = 3.0;   // TP3 Risk:Reward ratio

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
int g_h_stoch_1 = INVALID_HANDLE;
int g_h_stoch_2 = INVALID_HANDLE;
int g_h_ma_1    = INVALID_HANDLE;
int g_h_ma_2    = INVALID_HANDLE;

datetime g_lastBar_1 = 0;
datetime g_lastBar_2 = 0;

double g_lastBuyPrice_1  = -1.0;
double g_lastSellPrice_1 = -1.0;
double g_lastBuyPrice_2  = -1.0;
double g_lastSellPrice_2 = -1.0;

int      g_state_1 = SIG_NONE;
datetime g_bar_1   = 0;

int      g_state_2 = SIG_NONE;
datetime g_bar_2   = 0;

datetime g_fired_bar_1 = 0;
datetime g_fired_bar_2 = 0;

int      g_lastCooldownSig  = SIG_NONE;
datetime g_lastCooldownTime = 0;

datetime g_lastMACrossBar   = 0;   // bar guard for EMA cross detection

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
   g_lastMACrossBar   = 0;

   int tf2K    = InpTF2UseOwnStoch ? InpStoch_K2    : InpStoch_K;
   int tf2D    = InpTF2UseOwnStoch ? InpStoch_D2    : InpStoch_D;
   int tf2Slow = InpTF2UseOwnStoch ? InpStoch_Slow2 : InpStoch_Slow;

   g_h_stoch_1 = iStochastic(_Symbol, InpTF1, InpStoch_K, InpStoch_D, InpStoch_Slow, MODE_SMA, STO_LOWHIGH);
   g_h_stoch_2 = iStochastic(_Symbol, InpTF2, tf2K,       tf2D,       tf2Slow,       MODE_SMA, STO_LOWHIGH);

   if(g_h_stoch_1 == INVALID_HANDLE){ Alert("StochRSI: Failed Stoch TF1 handle"); return INIT_FAILED; }
   if(g_h_stoch_2 == INVALID_HANDLE){ Alert("StochRSI: Failed Stoch TF2 handle"); return INIT_FAILED; }

   // Slow EMA – used for re-entry slope filter and EMA cross slow side
   if(InpEnableMAFilter || InpEMACrossEnable)
   {
      g_h_ma_1 = iMA(_Symbol, InpEMACross_TF, InpMA_Period, 0, InpMA_Method, PRICE_CLOSE);
      if(g_h_ma_1 == INVALID_HANDLE){ Alert("StochRSI: Failed slow EMA handle"); return INIT_FAILED; }
   }
   // Fast EMA – used for EMA cross fast side
   if(InpEMACrossEnable)
   {
      g_h_ma_2 = iMA(_Symbol, InpEMACross_TF, InpMA_Period2, 0, InpMA_Method, PRICE_CLOSE);
      if(g_h_ma_2 == INVALID_HANDLE){ Alert("StochRSI: Failed fast EMA handle"); return INIT_FAILED; }
   }

   EventSetTimer(2);

   Print("StochRSI v4.34 loaded  ", _Symbol,
         " | TF1:", TFName(InpTF1),
         " Stoch(", InpStoch_K, ",", InpStoch_D, ",", InpStoch_Slow, ")",
         " | TF2:", TFName(InpTF2),
         " Stoch(", tf2K, ",", tf2D, ",", tf2Slow, ")",
         " | EMA cross:", TFName(InpEMACross_TF),
         " EMA", InpMA_Period2, "/EMA", InpMA_Period,
         " enabled:", (InpEMACrossEnable ? "YES" : "NO"),
         " | OB:", InpOB_Level, " OS:", InpOS_Level, " Lookback:", InpOSLookback,
         " | SL:", InpSLLookback, "bars  TP RR:", InpTP1_RR, "/", InpTP2_RR, "/", InpTP3_RR,
         " | Cooldown:", InpSignalCooldownMin, "min Gap:", InpMinPriceGap, "pts");

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
                                  g_state_1, g_bar_1,
                                  true);               // TF1 always strict

   if(InpEnableTF2)
      changed2 = ProcessTimeframe(InpTF2, g_h_stoch_2, g_h_ma_2,
                                  g_lastBar_2,
                                  g_lastBuyPrice_2, g_lastSellPrice_2,
                                  g_state_2, g_bar_2,
                                  InpTF2StrictZones);  // default false = direction-only

   if(changed1 || changed2)
      CheckConfirmation();

   CheckMACross();
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
//  Direction helpers
//+------------------------------------------------------------------+
bool IsBullish(int s) { return s == SIG_BUY || s == SIG_BUY_AGAIN;   }
bool IsBearish(int s) { return s == SIG_SELL || s == SIG_SELL_AGAIN; }

//+------------------------------------------------------------------+
//  CalcTPSL – swing SL + R:R targets
//+------------------------------------------------------------------+
void CalcTPSL(int sigType, double entry,
              double &sl, double &tp1, double &tp2, double &tp3)
{
   double arr[];
   ArrayResize(arr, InpSLLookback);
   double risk;

   if(IsBullish(sigType))
   {
      sl = (CopyLow(_Symbol, InpTF1, 1, InpSLLookback, arr) == InpSLLookback)
           ? arr[ArrayMinimum(arr)]
           : entry - InpMinPriceGap * _Point;
      risk = entry - sl;
      if(risk <= 0) risk = InpMinPriceGap * _Point;
      tp1 = entry + risk * InpTP1_RR;
      tp2 = entry + risk * InpTP2_RR;
      tp3 = entry + risk * InpTP3_RR;
   }
   else
   {
      sl = (CopyHigh(_Symbol, InpTF1, 1, InpSLLookback, arr) == InpSLLookback)
           ? arr[ArrayMaximum(arr)]
           : entry + InpMinPriceGap * _Point;
      risk = sl - entry;
      if(risk <= 0) risk = InpMinPriceGap * _Point;
      tp1 = entry - risk * InpTP1_RR;
      tp2 = entry - risk * InpTP2_RR;
      tp3 = entry - risk * InpTP3_RR;
   }
}

//+------------------------------------------------------------------+
//  FireArmedAlert – Stage 1: TF1 has armed a new signal
//  Push: "BUY READY (RISKY) XAUUSD.p  Price:4176.52"
//+------------------------------------------------------------------+
void FireArmedAlert(int sigType, double price)
{
   string msg = SignalTypeName(sigType)
              + " READY (RISKY) " + _Symbol
              + "  Price:" + DoubleToString(price, _Digits);

   if(InpEnablePush && !SendNotification(msg))
      Print("Push failed. Ensure mobile terminal is linked.");
   if(InpEnablePopup)
      Alert(msg);
   if(InpEnablePrint)
      Print("[ARMED] ", msg);
}

//+------------------------------------------------------------------+
//  FireConfirmedAlert – Stage 2: both TFs agree
//  Push: "BUY NOW (SAFE) XAUUSD.p  Entry:4182  SL:4173  TP1:4191  TP2:4200  TP3:4209"
//+------------------------------------------------------------------+
void FireConfirmedAlert(int sigType)
{
   double entry = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl, tp1, tp2, tp3;
   CalcTPSL(sigType, entry, sl, tp1, tp2, tp3);

   string msg = SignalTypeName(sigType)
              + " NOW (SAFE) " + _Symbol
              + "  Entry:" + DoubleToString(entry, _Digits)
              + "  SL:"    + DoubleToString(sl,    _Digits)
              + "  TP1:"   + DoubleToString(tp1,   _Digits)
              + "  TP2:"   + DoubleToString(tp2,   _Digits)
              + "  TP3:"   + DoubleToString(tp3,   _Digits);

   if(InpEnablePush && !SendNotification(msg))
      Print("Push failed. Ensure mobile terminal is linked.");
   if(InpEnablePopup)
      Alert(msg);
   if(InpEnablePrint)
      Print("*** SIGNAL *** ", msg);
}

//+------------------------------------------------------------------+
//  CheckMACross – independent EMA cross secondary signal
//  Fast EMA crosses slow EMA → push "EMA CROSS M5 BUY/SELL SYMBOL"
//+------------------------------------------------------------------+
void CheckMACross()
{
   if(!InpEMACrossEnable)                               return;
   if(g_h_ma_1 == INVALID_HANDLE ||
      g_h_ma_2 == INVALID_HANDLE)                       return;

   datetime barTimes[3];
   if(CopyTime(_Symbol, InpEMACross_TF, 0, 3, barTimes) < 3) return;
   if(barTimes[1] == g_lastMACrossBar)                  return;
   g_lastMACrossBar = barTimes[1];

   double slow[3], fast[3];
   if(CopyBuffer(g_h_ma_1, 0, 0, 3, slow) < 3) return;  // slow EMA (34)
   if(CopyBuffer(g_h_ma_2, 0, 0, 3, fast) < 3) return;  // fast EMA (16)

   bool crossUp   = (fast[2] <= slow[2]) && (fast[1] > slow[1]);
   bool crossDown = (fast[2] >= slow[2]) && (fast[1] < slow[1]);
   if(!crossUp && !crossDown) return;

   string dir   = crossUp ? "BUY" : "SELL";
   string tfStr = TFName(InpEMACross_TF);
   double price = iClose(_Symbol, InpEMACross_TF, 1);

   string msg = "EMA CROSS " + tfStr + " " + dir + " " + _Symbol
              + "  Price:" + DoubleToString(price,   _Digits)
              + "  EMA"   + IntegerToString(InpMA_Period2) + ":" + DoubleToString(fast[1], _Digits)
              + "  EMA"   + IntegerToString(InpMA_Period)  + ":" + DoubleToString(slow[1], _Digits);

   if(InpEnablePush && !SendNotification(msg))
      Print("Push failed. Ensure mobile terminal is linked.");
   if(InpEnablePopup)
      Alert(msg);
   if(InpEnablePrint)
      Print("[EMA CROSS] ", msg);
}

//+------------------------------------------------------------------+
//  ProcessTimeframe – returns true if state changed
//+------------------------------------------------------------------+
bool ProcessTimeframe(ENUM_TIMEFRAMES  tf,
                      int              h_stoch,
                      int              h_ma,
                      datetime        &lastBar,
                      double          &lastBuyPrice,
                      double          &lastSellPrice,
                      int             &state,
                      datetime        &stateBar,
                      bool             strictZones)
{
   datetime barTimes[3];
   if(CopyTime(_Symbol, tf, 0, 3, barTimes) < 3) return false;
   if(barTimes[1] == lastBar)                     return false;
   lastBar = barTimes[1];

   int    kCopy = InpOSLookback + 2;
   double k_buf[];
   double d_buf[3];
   ArrayResize(k_buf, kCopy);
   if(CopyBuffer(h_stoch, MAIN_LINE,   0, kCopy, k_buf) < kCopy) return false;
   if(CopyBuffer(h_stoch, SIGNAL_LINE, 0, 3,     d_buf) < 3)     return false;

   double k1 = k_buf[1];
   double d1 = d_buf[1];
   double k2 = k_buf[2];
   double d2 = d_buf[2];

   bool crossedUp   = (k2 <= d2) && (k1 > d1);
   bool crossedDown = (k2 >= d2) && (k1 < d1);
   if(!crossedUp && !crossedDown) return false;

   double barC = iClose(_Symbol, tf, 1);

   //--- ══ LOOSE CONFIRMATION MODE (TF2 default) ═════════════════════
   // Any K/D cross sets direction state. No OB/OS zone required.
   if(!strictZones)
   {
      if(crossedUp)
      {
         state    = SIG_BUY;
         stateBar = barTimes[1];
         Print("[STATE ", TFName(tf), "] → BUY (confirm K=", DoubleToString(k1,2), " cross UP)");
         return true;
      }
      if(crossedDown)
      {
         state    = SIG_SELL;
         stateBar = barTimes[1];
         Print("[STATE ", TFName(tf), "] → SELL (confirm K=", DoubleToString(k1,2), " cross DN)");
         return true;
      }
      return false;
   }

   //--- ══ Scan for recent OB/OS touch ═══════════════════════════════
   bool recentlyOS = false;
   bool recentlyOB = false;
   for(int i = 1; i <= InpOSLookback && i < kCopy; i++)
   {
      if(k_buf[i] <= InpOS_Level) recentlyOS = true;
      if(k_buf[i] >= InpOB_Level) recentlyOB = true;
   }

   //--- ══ MA slope for re-entry trend filter ════════════════════════
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
   if(crossedUp && recentlyOS)
   {
      lastBuyPrice = barC;
      state        = SIG_BUY;
      stateBar     = barTimes[1];
      Print("[STATE ", TFName(tf), "] → BUY  K=", DoubleToString(k1,2),
            " recentlyOS | price=", DoubleToString(barC, _Digits));
      FireArmedAlert(SIG_BUY, barC);
      return true;
   }

   //--- ══ PRIMARY SELL ══════════════════════════════════════════════
   if(crossedDown && recentlyOB)
   {
      lastSellPrice = barC;
      state         = SIG_SELL;
      stateBar      = barTimes[1];
      Print("[STATE ", TFName(tf), "] → SELL  K=", DoubleToString(k1,2),
            " recentlyOB | price=", DoubleToString(barC, _Digits));
      FireArmedAlert(SIG_SELL, barC);
      return true;
   }

   //--- ══ SELL AGAIN ════════════════════════════════════════════════
   if(crossedDown && k1 >= InpSellAgain_Low && k1 <= InpSellAgain_High)
   {
      if(!maDowntrend || lastSellPrice < 0.0) return false;
      double minPrice = lastSellPrice - InpMinPriceGap * _Point;
      if(barC < minPrice)
      {
         double oldPrice = lastSellPrice;
         lastSellPrice   = barC;
         state           = SIG_SELL_AGAIN;
         stateBar        = barTimes[1];
         Print("[STATE ", TFName(tf), "] → SELL AGAIN  K=", DoubleToString(k1,2),
               "  C=", DoubleToString(barC, _Digits),
               " < prev:", DoubleToString(oldPrice, _Digits));
         FireArmedAlert(SIG_SELL_AGAIN, barC);
         return true;
      }
      return false;
   }

   //--- ══ BUY AGAIN ═════════════════════════════════════════════════
   if(crossedUp && k1 >= InpBuyAgain_Low && k1 <= InpBuyAgain_High)
   {
      if(!maUptrend || lastBuyPrice < 0.0) return false;
      double minPrice = lastBuyPrice + InpMinPriceGap * _Point;
      if(barC > minPrice)
      {
         double oldPrice = lastBuyPrice;
         lastBuyPrice    = barC;
         state           = SIG_BUY_AGAIN;
         stateBar        = barTimes[1];
         Print("[STATE ", TFName(tf), "] → BUY AGAIN  K=", DoubleToString(k1,2),
               "  C=", DoubleToString(barC, _Digits),
               " > prev:", DoubleToString(oldPrice, _Digits));
         FireArmedAlert(SIG_BUY_AGAIN, barC);
         return true;
      }
      return false;
   }

   return false;
}

//+------------------------------------------------------------------+
//  CheckConfirmation
//  TF1 is signal source. TF2 must agree in direction:
//    TF1 bullish (BUY/BUY AGAIN) + TF2 BUY  → confirmed
//    TF1 bearish (SELL/SELL AGAIN) + TF2 SELL → confirmed
//+------------------------------------------------------------------+
void CheckConfirmation()
{
   if(!InpEnableTF1 || !InpEnableTF2)
   {
      if(InpEnableTF1 && g_state_1 != SIG_NONE && g_bar_1 != g_fired_bar_1)
      {
         if(PassesCooldown(g_state_1, g_bar_1))
         {
            FireConfirmedAlert(g_state_1);
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
            FireConfirmedAlert(g_state_2);
            g_fired_bar_2      = g_bar_2;
            g_lastCooldownSig  = g_state_2;
            g_lastCooldownTime = g_bar_2;
         }
         else
            Print("[COOLDOWN] ", SignalTypeName(g_state_2), " blocked (TF2)");
      }
      return;
   }

   if(g_state_1 == SIG_NONE || g_state_2 == SIG_NONE) return;

   bool bullish = IsBullish(g_state_1) && IsBullish(g_state_2);
   bool bearish = IsBearish(g_state_1) && IsBearish(g_state_2);
   if(!bullish && !bearish)
   {
      Print("[WAIT] TF1=", SignalTypeName(g_state_1),
            " TF2=", SignalTypeName(g_state_2), " – direction mismatch");
      return;
   }

   if(g_bar_1 == g_fired_bar_1 && g_bar_2 == g_fired_bar_2) return;

   datetime confirmedTime = MathMax(g_bar_1, g_bar_2);
   if(!PassesCooldown(g_state_1, confirmedTime))
   {
      Print("[COOLDOWN] ", SignalTypeName(g_state_1),
            " blocked – within ", InpSignalCooldownMin, "min");
      g_fired_bar_1 = g_bar_1;
      g_fired_bar_2 = g_bar_2;
      return;
   }

   FireConfirmedAlert(g_state_1);

   g_fired_bar_1      = g_bar_1;
   g_fired_bar_2      = g_bar_2;
   g_lastCooldownSig  = g_state_1;
   g_lastCooldownTime = confirmedTime;
}

//+------------------------------------------------------------------+
//  END OF FILE
//+------------------------------------------------------------------+
