//+------------------------------------------------------------------+
//|                    StochRSI_MTF_Alert.mq5                        |
//|    Stochastic K/D Cross with K-Level Zone Filter + Pivots        |
//|    Dual-TF State Machine – both TFs must agree, no expiry        |
//|                                                                  |
//|  SIGNAL LOGIC (zone = K level at the moment of cross):           |
//|   BUY        – K crosses D UP   while K <= OS level  (e.g. 20)   |
//|   SELL       – K crosses D DOWN while K >= OB level  (e.g. 80)   |
//|   BUY AGAIN  – K crosses D UP   while K in 20–40               |
//|                AND cross K > last BUY pivot  (higher high)       |
//|   SELL AGAIN – K crosses D DOWN while K in 60–80               |
//|                AND cross K < last SELL pivot (lower low)         |
//|                                                                  |
//|  CONFIRMATION: alert fires only when TF1 AND TF2 hold the same   |
//|  state. No expiry – states persist until overwritten.            |
//+------------------------------------------------------------------+
#property copyright   "Custom Indicator"
#property version     "3.00"
#property description "Stoch K/D cross filtered by K level – dual-TF state machine alerts"
#property indicator_chart_window
#property indicator_plots 0

//════════════════════════════════════════════════════════════════════
//  INPUT PARAMETERS
//════════════════════════════════════════════════════════════════════
input group "══════ Stochastic Settings ══════"
input int    InpStoch_K    = 50;    // %K Period
input int    InpStoch_D    = 7;     // %D Period (signal)
input int    InpStoch_Slow = 11;    // Slowing

input group "══════ OB / OS Levels ══════"
input double InpOB_Level   = 80.0;  // Overbought – K above this → SELL zone
input double InpOS_Level   = 20.0;  // Oversold   – K below this → BUY zone

input group "══════ Re-Entry Zone Filters (K level) ══════"
input double InpSellAgain_High = 80.0;  // Sell-Again K upper
input double InpSellAgain_Low  = 60.0;  // Sell-Again K lower
input double InpBuyAgain_High  = 40.0;  // Buy-Again K upper
input double InpBuyAgain_Low   = 20.0;  // Buy-Again K lower

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
int g_h_stoch_1 = INVALID_HANDLE;
int g_h_stoch_2 = INVALID_HANDLE;

// Last processed bar timestamps
datetime g_lastBar_1 = 0;
datetime g_lastBar_2 = 0;

// Pivot memory – K value at last primary signal
double g_lastOB_pivot_1 = -1.0;
double g_lastOS_pivot_1 = -1.0;
double g_lastOB_pivot_2 = -1.0;
double g_lastOS_pivot_2 = -1.0;

// TF state (persists until a new signal overwrites it)
int      g_state_1 = SIG_NONE;
datetime g_bar_1   = 0;

int      g_state_2 = SIG_NONE;
datetime g_bar_2   = 0;

// Bar pair at last confirmed fire – prevents re-firing same agreement
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

   g_h_stoch_1 = iStochastic(_Symbol, InpTF1, InpStoch_K, InpStoch_D, InpStoch_Slow, MODE_SMA, STO_LOWHIGH);
   g_h_stoch_2 = iStochastic(_Symbol, InpTF2, InpStoch_K, InpStoch_D, InpStoch_Slow, MODE_SMA, STO_LOWHIGH);

   if(g_h_stoch_1 == INVALID_HANDLE){ Alert("StochRSI: Failed Stoch TF1 handle"); return INIT_FAILED; }
   if(g_h_stoch_2 == INVALID_HANDLE){ Alert("StochRSI: Failed Stoch TF2 handle"); return INIT_FAILED; }

   EventSetTimer(2);

   Print("StochRSI loaded  ", _Symbol,
         " | Stoch(", InpStoch_K, ",", InpStoch_D, ",", InpStoch_Slow, ")",
         " | OB:", InpOB_Level, " OS:", InpOS_Level,
         " | TF1:", TFName(InpTF1), " TF2:", TFName(InpTF2));

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
      changed1 = ProcessTimeframe(InpTF1, g_h_stoch_1,
                                  g_lastBar_1,
                                  g_lastOB_pivot_1, g_lastOS_pivot_1,
                                  g_state_1, g_bar_1);

   if(InpEnableTF2)
      changed2 = ProcessTimeframe(InpTF2, g_h_stoch_2,
                                  g_lastBar_2,
                                  g_lastOB_pivot_2, g_lastOS_pivot_2,
                                  g_state_2, g_bar_2);

   if(changed1 || changed2)
      CheckConfirmation();
}

//+------------------------------------------------------------------+
//  ProcessTimeframe
//  Returns true if the state changed on this call.
//+------------------------------------------------------------------+
bool ProcessTimeframe(ENUM_TIMEFRAMES  tf,
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

   double k_buf[3], d_buf[3];
   if(CopyBuffer(h_stoch, MAIN_LINE,   0, 3, k_buf) < 3) return false;
   if(CopyBuffer(h_stoch, SIGNAL_LINE, 0, 3, d_buf) < 3) return false;

   double k1 = k_buf[1];   // last closed bar K
   double d1 = d_buf[1];   // last closed bar D
   double k2 = k_buf[2];   // prior closed bar K
   double d2 = d_buf[2];   // prior closed bar D

   bool crossedUp   = (k2 <= d2) && (k1 > d1);
   bool crossedDown = (k2 >= d2) && (k1 < d1);
   if(!crossedUp && !crossedDown) return false;

   //--- ══ PRIMARY BUY ══════════════════════════════════════════════
   //    K crosses D upward while K is in oversold zone
   if(crossedUp && k1 <= InpOS_Level)
   {
      lastOS_pivot = k1;
      state        = SIG_BUY;
      stateBar     = barTimes[1];
      return true;
   }

   //--- ══ PRIMARY SELL ══════════════════════════════════════════════
   //    K crosses D downward while K is in overbought zone
   if(crossedDown && k1 >= InpOB_Level)
   {
      lastOB_pivot = k1;
      state        = SIG_SELL;
      stateBar     = barTimes[1];
      return true;
   }

   //--- ══ SELL AGAIN ════════════════════════════════════════════════
   //    K crosses D downward in mid-range (60–80)
   //    K must be lower than last SELL pivot (lower low)
   if(crossedDown && k1 >= InpSellAgain_Low && k1 <= InpSellAgain_High)
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
   //    K crosses D upward in mid-range (20–40)
   //    K must be higher than last BUY pivot (higher high)
   if(crossedUp && k1 >= InpBuyAgain_Low && k1 <= InpBuyAgain_High)
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

   if(g_state_1 == SIG_NONE || g_state_2 == SIG_NONE)          return;
   if(g_state_1 != g_state_2)                                   return;
   if(g_bar_1 == g_fired_bar_1 && g_bar_2 == g_fired_bar_2)    return;

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
