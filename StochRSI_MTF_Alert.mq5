//+------------------------------------------------------------------+
//|                    StochRSI_MTF_Alert.mq5                        |
//|    Stochastic K/D Cross with RSI(1) Level Filter + Pivots        |
//|    Dual-TF State Machine – both TFs must agree, no expiry        |
//|                                                                  |
//|  HOW IT WORKS:                                                   |
//|   Each TF independently watches for crosses and holds its last   |
//|   signal state indefinitely. A confirmed alert fires the moment  |
//|   both TFs hold the same state. It will not re-fire on the same  |
//|   agreement; at least one TF must transition before a repeat.    |
//|                                                                  |
//|  SIGNAL LOGIC:                                                   |
//|   BUY        – K crosses D UP   while RSI in OS zone  (1–8)      |
//|   SELL       – K crosses D DOWN while RSI in OB zone  (90–98)    |
//|   BUY AGAIN  – K crosses D UP   while RSI in 15–40              |
//|                AND cross K > last BUY pivot  (higher high)       |
//|   SELL AGAIN – K crosses D DOWN while RSI in 60–80              |
//|                AND cross K < last SELL pivot (lower low)         |
//+------------------------------------------------------------------+
#property copyright   "Custom Indicator"
#property version     "2.10"
#property description "Stoch K/D cross filtered by RSI(1) – dual-TF state machine alerts"
#property indicator_chart_window
#property indicator_plots 0

//════════════════════════════════════════════════════════════════════
//  INPUT PARAMETERS
//════════════════════════════════════════════════════════════════════
input group "══════ RSI Settings ══════"
input int    InpRSI_Period     = 1;      // RSI Period
input double InpRSI_OB_High   = 100.0;  // OB Upper Bound
input double InpRSI_OB_Low    = 90.0;   // OB Lower Bound
input double InpRSI_OS_High   = 8.0;    // OS Upper Bound
input double InpRSI_OS_Low    = 0.0;    // OS Lower Bound

input group "══════ Stochastic Settings ══════"
input int    InpStoch_K       = 50;     // %K Period
input int    InpStoch_D       = 7;      // %D Period (signal)
input int    InpStoch_Slow    = 11;     // Slowing

input group "══════ Re-Entry Zone Filters ══════"
input double InpSellAgain_High = 80.0;  // Sell-Again RSI upper
input double InpSellAgain_Low  = 60.0;  // Sell-Again RSI lower
input double InpBuyAgain_High  = 40.0;  // Buy-Again RSI upper
input double InpBuyAgain_Low   = 15.0;  // Buy-Again RSI lower

input group "══════ Timeframe Selection ══════"
input ENUM_TIMEFRAMES InpTF1       = PERIOD_M4;  // Timeframe 1
input bool            InpEnableTF1 = true;        // Enable TF1
input ENUM_TIMEFRAMES InpTF2       = PERIOD_M6;  // Timeframe 2
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
int g_h_rsi_1   = INVALID_HANDLE;
int g_h_stoch_1 = INVALID_HANDLE;
int g_h_rsi_2   = INVALID_HANDLE;
int g_h_stoch_2 = INVALID_HANDLE;

// Last processed bar timestamps (gate: process only on new closed bar)
datetime g_lastBar_1 = 0;
datetime g_lastBar_2 = 0;

// Pivot memory – K value at last primary signal
double g_lastOB_pivot_1 = -1.0;
double g_lastOS_pivot_1 = -1.0;
double g_lastOB_pivot_2 = -1.0;
double g_lastOS_pivot_2 = -1.0;

// TF1 state (persists until a new signal overwrites it)
int      g_state_1 = SIG_NONE;
datetime g_bar_1   = 0;

// TF2 state
int      g_state_2 = SIG_NONE;
datetime g_bar_2   = 0;

// Tracks the bar pair at the last confirmed fire.
// Prevents re-firing on the same agreement without a new transition.
datetime g_fired_bar_1 = 0;
datetime g_fired_bar_2 = 0;

//+------------------------------------------------------------------+
//  INIT
//+------------------------------------------------------------------+
int OnInit()
{
   g_lastBar_1 = g_lastBar_2 = 0;
   g_lastOB_pivot_1 = g_lastOS_pivot_1 = -1.0;
   g_lastOB_pivot_2 = g_lastOS_pivot_2 = -1.0;
   g_state_1 = g_state_2 = SIG_NONE;
   g_bar_1   = g_bar_2   = 0;
   g_fired_bar_1 = g_fired_bar_2 = 0;

   g_h_rsi_1   = iRSI       (_Symbol, InpTF1, InpRSI_Period, PRICE_CLOSE);
   g_h_stoch_1 = iStochastic(_Symbol, InpTF1, InpStoch_K, InpStoch_D, InpStoch_Slow, MODE_SMA, STO_LOWHIGH);
   g_h_rsi_2   = iRSI       (_Symbol, InpTF2, InpRSI_Period, PRICE_CLOSE);
   g_h_stoch_2 = iStochastic(_Symbol, InpTF2, InpStoch_K, InpStoch_D, InpStoch_Slow, MODE_SMA, STO_LOWHIGH);

   if(g_h_rsi_1   == INVALID_HANDLE){ Alert("StochRSI: Failed RSI TF1 handle");   return INIT_FAILED; }
   if(g_h_stoch_1 == INVALID_HANDLE){ Alert("StochRSI: Failed Stoch TF1 handle"); return INIT_FAILED; }
   if(g_h_rsi_2   == INVALID_HANDLE){ Alert("StochRSI: Failed RSI TF2 handle");   return INIT_FAILED; }
   if(g_h_stoch_2 == INVALID_HANDLE){ Alert("StochRSI: Failed Stoch TF2 handle"); return INIT_FAILED; }

   EventSetTimer(2);

   Print("StochRSI State Machine loaded  ", _Symbol,
         " | TF1:", TFName(InpTF1), " TF2:", TFName(InpTF2));

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//  DEINIT
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();

   if(g_h_rsi_1   != INVALID_HANDLE) IndicatorRelease(g_h_rsi_1);
   if(g_h_stoch_1 != INVALID_HANDLE) IndicatorRelease(g_h_stoch_1);
   if(g_h_rsi_2   != INVALID_HANDLE) IndicatorRelease(g_h_rsi_2);
   if(g_h_stoch_2 != INVALID_HANDLE) IndicatorRelease(g_h_stoch_2);
}

//+------------------------------------------------------------------+
//  TIMER
//+------------------------------------------------------------------+
void OnTimer() { CheckAllTimeframes(); }

//+------------------------------------------------------------------+
//  MAIN CALCULATION
//+------------------------------------------------------------------+
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
      changed1 = ProcessTimeframe(InpTF1,
                                  g_h_rsi_1, g_h_stoch_1,
                                  g_lastBar_1,
                                  g_lastOB_pivot_1, g_lastOS_pivot_1,
                                  g_state_1, g_bar_1);

   if(InpEnableTF2)
      changed2 = ProcessTimeframe(InpTF2,
                                  g_h_rsi_2, g_h_stoch_2,
                                  g_lastBar_2,
                                  g_lastOB_pivot_2, g_lastOS_pivot_2,
                                  g_state_2, g_bar_2);

   if(changed1 || changed2)
      CheckConfirmation();
}

//+------------------------------------------------------------------+
//  ProcessTimeframe
//  Watches one TF for signal crosses and updates its state.
//  Returns true if the state changed on this call.
//+------------------------------------------------------------------+
bool ProcessTimeframe(ENUM_TIMEFRAMES  tf,
                      int              h_rsi,
                      int              h_stoch,
                      datetime        &lastBar,
                      double          &lastOB_pivot,
                      double          &lastOS_pivot,
                      int             &state,
                      datetime        &stateBar)
{
   datetime barTimes[3];
   if(CopyTime(_Symbol, tf, 0, 3, barTimes) < 3) return false;
   if(barTimes[1] == lastBar)                     return false;
   lastBar = barTimes[1];

   double rsi_buf[3], k_buf[3], d_buf[3];
   if(CopyBuffer(h_rsi,   0,           0, 3, rsi_buf) < 3) return false;
   if(CopyBuffer(h_stoch, MAIN_LINE,   0, 3, k_buf)   < 3) return false;
   if(CopyBuffer(h_stoch, SIGNAL_LINE, 0, 3, d_buf)   < 3) return false;

   double rsi = rsi_buf[1];
   double k1  = k_buf[1];
   double d1  = d_buf[1];
   double k2  = k_buf[2];
   double d2  = d_buf[2];

   bool crossedUp   = (k2 <= d2) && (k1 > d1);
   bool crossedDown = (k2 >= d2) && (k1 < d1);

   Print(TFName(tf), " bar=", TimeToString(barTimes[1]),
         " RSI=", DoubleToString(rsi, 2),
         " K1=", DoubleToString(k1, 2), " D1=", DoubleToString(d1, 2),
         " K2=", DoubleToString(k2, 2), " D2=", DoubleToString(d2, 2),
         " crossUp=", crossedUp, " crossDn=", crossedDown);

   if(!crossedUp && !crossedDown) return false;

   //--- ══ PRIMARY BUY ══════════════════════════════════════════════
   if(crossedUp && rsi >= InpRSI_OS_Low && rsi <= InpRSI_OS_High)
   {
      lastOS_pivot = k1;
      state        = SIG_BUY;
      stateBar     = barTimes[1];
      return true;
   }

   //--- ══ PRIMARY SELL ══════════════════════════════════════════════
   if(crossedDown && rsi >= InpRSI_OB_Low && rsi <= InpRSI_OB_High)
   {
      lastOB_pivot = k1;
      state        = SIG_SELL;
      stateBar     = barTimes[1];
      return true;
   }

   //--- ══ SELL AGAIN ════════════════════════════════════════════════
   if(crossedDown && rsi >= InpSellAgain_Low && rsi <= InpSellAgain_High)
   {
      if(lastOB_pivot > 0.0 && k1 < lastOB_pivot)
      {
         lastOB_pivot = k1;
         state        = SIG_SELL_AGAIN;
         stateBar     = barTimes[1];
         return true;
      }
      return false;
   }

   //--- ══ BUY AGAIN ═════════════════════════════════════════════════
   if(crossedUp && rsi >= InpBuyAgain_Low && rsi <= InpBuyAgain_High)
   {
      if(lastOS_pivot > 0.0 && k1 > lastOS_pivot)
      {
         lastOS_pivot = k1;
         state        = SIG_BUY_AGAIN;
         stateBar     = barTimes[1];
         return true;
      }
      return false;
   }

   return false;
}

//+------------------------------------------------------------------+
//  CheckConfirmation
//  Called only when at least one TF just changed state.
//  Fires once per unique bar-pair agreement; does not expire.
//+------------------------------------------------------------------+
void CheckConfirmation()
{
   //--- Single-TF mode: fire directly
   if(!InpEnableTF1 || !InpEnableTF2)
   {
      if(InpEnableTF1 && g_state_1 != SIG_NONE && g_bar_1 != g_fired_bar_1)
      {
         FireAlert(SignalTypeName(g_state_1) + " " + _Symbol);
         g_fired_bar_1 = g_bar_1;
      }
      if(InpEnableTF2 && g_state_2 != SIG_NONE && g_bar_2 != g_fired_bar_2)
      {
         FireAlert(SignalTypeName(g_state_2) + " " + _Symbol);
         g_fired_bar_2 = g_bar_2;
      }
      return;
   }

   if(g_state_1 == SIG_NONE || g_state_2 == SIG_NONE) return;
   if(g_state_1 != g_state_2)                          return;
   if(g_bar_1 == g_fired_bar_1 && g_bar_2 == g_fired_bar_2) return;

   FireAlert(SignalTypeName(g_state_1) + " " + _Symbol);

   g_fired_bar_1 = g_bar_1;
   g_fired_bar_2 = g_bar_2;
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
   if(InpEnablePush && !SendNotification(msg))
      Print("Push failed. Ensure mobile terminal is linked.");

   if(InpEnablePopup)
      Alert(msg);

   if(InpEnablePrint)
      Print(msg);
}

//+------------------------------------------------------------------+
//  END OF FILE
//+------------------------------------------------------------------+
