//+------------------------------------------------------------------+
//|                                       SwingPointsLiquidity.mq5  |
//|          Port of "Swing Points and Liquidity" by LeviathanCap.  |
//|          + Market Structure (HH / HL / LH / LL)                 |
//|          + CHoCH Detection                                       |
//|          + FVG / OB Zone Detection for MSS Entry                |
//|          + Push Notifications with SL / TP1 / TP2 / TP3         |
//+------------------------------------------------------------------+
#property copyright "bidiisStrategy"
#property version   "1.60"
#property indicator_chart_window
#property indicator_plots   6
#property indicator_buffers 8

//--- Plot 0 : BUY  With-Trend  (HL confirmed in bull)
#property indicator_label1  "BUY - Bull"
#property indicator_type1   DRAW_ARROW
#property indicator_color1  clrLimeGreen
#property indicator_width1  2

//--- Plot 1 : BUY  Counter-Trend  (HL confirmed in bear)
#property indicator_label2  "BUY - Bear (CT)"
#property indicator_type2   DRAW_ARROW
#property indicator_color2  C'0,130,60'
#property indicator_width2  1

//--- Plot 2 : BUY  MSS  (price enters bullish FVG / OB after CHoCH)
#property indicator_label3  "BUY - MSS"
#property indicator_type3   DRAW_ARROW
#property indicator_color3  clrDeepSkyBlue
#property indicator_width3  2

//--- Plot 3 : SELL  With-Trend  (LH confirmed in bear)
#property indicator_label4  "SELL - Bear"
#property indicator_type4   DRAW_ARROW
#property indicator_color4  clrCrimson
#property indicator_width4  2

//--- Plot 4 : SELL  Counter-Trend  (LH confirmed in bull)
#property indicator_label5  "SELL - Bull (CT)"
#property indicator_type5   DRAW_ARROW
#property indicator_color5  C'140,40,50'
#property indicator_width5  1

//--- Plot 5 : SELL  MSS  (price enters bearish FVG / OB after CHoCH)
#property indicator_label6  "SELL - MSS"
#property indicator_type6   DRAW_ARROW
#property indicator_color6  clrOrangeRed
#property indicator_width6  2

// ================================================================
// INPUTS
// ================================================================
input group "=== Swing Detection ==="
input int    InpSwingRight   = 10;               // Bars Right
input int    InpSwingLeft    = 15;               // Bars Left

input group "=== Display ==="
input bool   InpShowBoxes    = true;             // Show Liquidity Boxes
input bool   InpShowLines    = true;             // Show Level Lines
input bool   InpExtendFill   = true;             // Extend Until Filled
input bool   InpHideFilled   = false;            // Hide Filled Levels
input bool   InpShowCTSig    = true;             // Show Counter-Trend Signals
input bool   InpShowMSSZones = true;             // Draw FVG / OB Zones on Chart

input group "=== Appearance ==="
input color  InpHighColor    = C'170,36,48';     // Swing High Colour
input color  InpLowColor     = C'102,187,106';   // Swing Low Colour
input ENUM_LINE_STYLE InpLineStyle = STYLE_DOT;  // Line Style
input int    InpLineWidth    = 1;                // Line Width
input double InpBoxWidth     = 0.7;              // Box Width % (0.1-2.0)

input group "=== Market Structure ==="
input bool   InpShowMSSLabel = true;             // Draw CHoCH label on chart
input color  InpMSSBullCol   = clrDeepSkyBlue;   // CHoCH → Bullish colour
input color  InpMSSBearCol   = clrOrangeRed;     // CHoCH → Bearish colour
input color  InpFVGColor     = C'0,100,180';     // FVG zone colour
input color  InpOBColor      = C'140,60,0';      // OB zone colour

input group "=== Alerts & Push ==="
input bool   InpAlerts       = true;             // Pop-up Alerts
input bool   InpPush         = true;             // Push Notifications (mobile)

// ================================================================
// BUFFERS  (6 plotted + 2 internal)
// ================================================================
double BufBuyBull[];    // plot 0
double BufBuyCT[];      // plot 1
double BufBuyMSS[];     // plot 2
double BufSellBear[];   // plot 3
double BufSellCT[];     // plot 4
double BufSellMSS[];    // plot 5
double BufPivHProc[];   // internal: pivot-high "already processed" flag
double BufPivLProc[];   // internal: pivot-low  "already processed" flag

// ================================================================
// CONSTANTS & GLOBALS
// ================================================================
const string PFX         = "SPL_";
const int    MAX_OBJECTS = 500;
const int    MAX_HISTORY = 60;

//--- Liquidity level tracking
struct SLevel
  {
   double   price;
   double   boxTop;
   double   boxBot;
   datetime t1;
   bool     isHigh;
   string   lineName;
   string   boxName;
  };

SLevel   g_lv[];
int      g_nLv = 0;

//--- Swing price history (for TP calculation)
double   g_swHi[]; int g_nSH = 0;
double   g_swLo[]; int g_nSL = 0;

//--- Market-structure state
double   g_lastPH    = 0;
double   g_lastPL    = 0;
int      g_lastPHBar = -1;
int      g_lastPLBar = -1;
int      g_trend     = 0;   // 0=undef  1=bull  -1=bear

//--- MSS zone tracking (FVG / OB zones in the CHoCH leg)
struct MSSZone
  {
   double   top;
   double   bot;
   datetime t1;        // creation left-edge time (stored to fix extension bug)
   bool     isFVG;
   bool     isBull;
   bool     active;
   string   boxName;
  };

MSSZone  g_mssZones[8];
int      g_nMSSZones = 0;
double   g_mssSL     = 0;    // SL for MSS trade (structural extreme BELOW/ABOVE zones)
bool     g_mssBull   = false;

//--- Per-direction alert dedup (fix: was single int → silenced second signal on same bar)
int      g_lastBuyAlertBar  = -1;
int      g_lastSellAlertBar = -1;
int      g_lastMSSAlertBar  = -1;
int      g_chochBar         = -1;  // bar index of most recent CHoCH (for MSS skip guard)
int      g_chochSeq         = 0;   // monotonic counter for unique MSS zone object names
datetime g_lastExtTime      = 0;   // bar open time of last extension pass (P1: skip same-bar ticks)

// ================================================================
// OnInit
// ================================================================
int OnInit()
  {
   if(InpSwingLeft < 2 || InpSwingRight < 2)
     {
      Alert("SP&L: InpSwingLeft and InpSwingRight must be >= 2");
      return INIT_PARAMETERS_INCORRECT;
     }

//--- 6 plotted buffers
   SetIndexBuffer(0, BufBuyBull,  INDICATOR_DATA);
   SetIndexBuffer(1, BufBuyCT,    INDICATOR_DATA);
   SetIndexBuffer(2, BufBuyMSS,   INDICATOR_DATA);
   SetIndexBuffer(3, BufSellBear, INDICATOR_DATA);
   SetIndexBuffer(4, BufSellCT,   INDICATOR_DATA);
   SetIndexBuffer(5, BufSellMSS,  INDICATOR_DATA);

//--- 2 internal tracking buffers (not plotted, used as "processed" flags)
   SetIndexBuffer(6, BufPivHProc, INDICATOR_CALCULATIONS);
   SetIndexBuffer(7, BufPivLProc, INDICATOR_CALCULATIONS);

//--- Circles (●) for all signal types — the confirmed pivot dot IS the signal
   PlotIndexSetInteger(0, PLOT_ARROW, 159);
   PlotIndexSetInteger(1, PLOT_ARROW, 159);
   PlotIndexSetInteger(2, PLOT_ARROW, 159);
   PlotIndexSetInteger(3, PLOT_ARROW, 159);
   PlotIndexSetInteger(4, PLOT_ARROW, 159);
   PlotIndexSetInteger(5, PLOT_ARROW, 159);

//--- Shift circles: buy below bar, sell above bar
   PlotIndexSetInteger(0, PLOT_ARROW_SHIFT,  8);
   PlotIndexSetInteger(1, PLOT_ARROW_SHIFT,  8);
   PlotIndexSetInteger(2, PLOT_ARROW_SHIFT,  8);
   PlotIndexSetInteger(3, PLOT_ARROW_SHIFT, -8);
   PlotIndexSetInteger(4, PLOT_ARROW_SHIFT, -8);
   PlotIndexSetInteger(5, PLOT_ARROW_SHIFT, -8);

   for(int p = 0; p < 6; p++)
      PlotIndexSetDouble(p, PLOT_EMPTY_VALUE, 0.0);

   IndicatorSetString(INDICATOR_SHORTNAME,
      StringFormat("SP&L (%d/%d)", InpSwingLeft, InpSwingRight));

   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   ObjectsDeleteAll(0, PFX);
  }

// ================================================================
// HELPERS : pivot detection  (index 0 = oldest bar)
// ================================================================
bool IsPivotHigh(const double &h[], int pos, int L, int R, int total)
  {
   if(pos - L < 0 || pos + R >= total) return false;
   double v = h[pos];
   for(int k = 1; k <= L; k++) if(h[pos - k] >= v) return false;
   for(int k = 1; k <= R; k++) if(h[pos + k] >= v) return false;
   return true;
  }

bool IsPivotLow(const double &l[], int pos, int L, int R, int total)
  {
   if(pos - L < 0 || pos + R >= total) return false;
   double v = l[pos];
   for(int k = 1; k <= L; k++) if(l[pos - k] <= v) return false;
   for(int k = 1; k <= R; k++) if(l[pos + k] <= v) return false;
   return true;
  }

// ================================================================
// HELPERS : swing history
// ================================================================
void AddSwingHigh(double p)
  {
   if(g_nSH >= MAX_HISTORY)
     { for(int i = 0; i < g_nSH - 1; i++) g_swHi[i] = g_swHi[i + 1]; g_nSH--; }
   ArrayResize(g_swHi, g_nSH + 1);
   g_swHi[g_nSH++] = p;
  }

void AddSwingLow(double p)
  {
   if(g_nSL >= MAX_HISTORY)
     { for(int i = 0; i < g_nSL - 1; i++) g_swLo[i] = g_swLo[i + 1]; g_nSL--; }
   ArrayResize(g_swLo, g_nSL + 1);
   g_swLo[g_nSL++] = p;
  }

// ================================================================
// HELPERS : TP calculation
// FindBuyTPs  → 3 nearest swing HIGHS strictly above `entry`, ascending
// FindSellTPs → 3 nearest swing LOWS  strictly below `entry`, descending
// ================================================================
void FindBuyTPs(double entry, double &tp1, double &tp2, double &tp3)
  {
   tp1 = tp2 = tp3 = 0.0;
   if(g_nSH == 0) return;
   double c[]; ArrayResize(c, g_nSH); int n = 0;
   for(int i = 0; i < g_nSH; i++)
      if(g_swHi[i] > entry) c[n++] = g_swHi[i];
   if(n == 0) return;
   ArrayResize(c, n);
   ArraySort(c);
   if(n >= 1) tp1 = c[0];
   if(n >= 2) tp2 = c[1];
   if(n >= 3) tp3 = c[2];
  }

void FindSellTPs(double entry, double &tp1, double &tp2, double &tp3)
  {
   tp1 = tp2 = tp3 = 0.0;
   if(g_nSL == 0) return;
   double c[]; ArrayResize(c, g_nSL); int n = 0;
   for(int i = 0; i < g_nSL; i++)
      if(g_swLo[i] < entry) c[n++] = g_swLo[i];
   if(n == 0) return;
   ArrayResize(c, n);
   ArraySort(c);
   // reverse → closest below entry first
   for(int i = 0, j = n - 1; i < j; i++, j--) { double t = c[i]; c[i] = c[j]; c[j] = t; }
   if(n >= 1) tp1 = c[0];
   if(n >= 2) tp2 = c[1];
   if(n >= 3) tp3 = c[2];
  }

// ================================================================
// HELPERS : notification
// Three separate dedup vars (buy/sell/mss) so simultaneous
// signals on the same bar are all delivered.
// ================================================================
string PriceStr(double p)
  { return (p > 0.0) ? DoubleToString(p, _Digits) : "N/A"; }

void FireSignal(const string &dir, const string &label,
                double sigPrice, double sl,
                double tp1, double tp2, double tp3,
                int confirmBar, bool isLive, int &dedupBar)
  {
   if(!isLive)              return;
   if(!InpAlerts && !InpPush) return;
   if(dedupBar == confirmBar) return;   // already fired this direction this bar
   dedupBar = confirmBar;

   string msg = dir + " " + _Symbol + " " + DoubleToString(sigPrice, _Digits) +
                " | " + label +
                " | SL: "  + PriceStr(sl)  +
                " | TP1: " + PriceStr(tp1) +
                " | TP2: " + PriceStr(tp2) +
                " | TP3: " + PriceStr(tp3);

   if(InpAlerts) Alert(msg);
   if(InpPush && !SendNotification(msg)) Print("Push failed: ", msg);
  }

// ================================================================
// HELPERS : object drawing
// ================================================================
void DrawLine(const string &name, double price,
              datetime t1, datetime t2, color col)
  {
   if(!InpShowLines) return;
   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_TREND, 0, t1, price, t2, price);
      ObjectSetInteger(0, name, OBJPROP_COLOR,      col);
      ObjectSetInteger(0, name, OBJPROP_STYLE,      InpLineStyle);
      ObjectSetInteger(0, name, OBJPROP_WIDTH,      InpLineWidth);
      ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT,  false);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN,     true);
     }
   else
     {
      ObjectSetInteger(0, name, OBJPROP_TIME,  0, t1);
      ObjectSetDouble (0, name, OBJPROP_PRICE, 0, price);
      ObjectSetInteger(0, name, OBJPROP_TIME,  1, t2);
      ObjectSetDouble (0, name, OBJPROP_PRICE, 1, price);
     }
  }

void DrawBox(const string &name, double top, double bot,
             datetime t1, datetime t2, color col)
  {
   if(!InpShowBoxes) return;
   color dim = (color)(((int)(((col >> 16) & 0xFF) * 0.22) << 16) |
                       ((int)(((col >>  8) & 0xFF) * 0.22) <<  8) |
                        (int)((col & 0xFF) * 0.22));
   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, top, t2, bot);
      ObjectSetInteger(0, name, OBJPROP_COLOR,       dim);
      ObjectSetInteger(0, name, OBJPROP_BGCOLOR,     dim);
      ObjectSetInteger(0, name, OBJPROP_FILL,        true);
      ObjectSetInteger(0, name, OBJPROP_BACK,        true);
      ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE,  false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN,      true);
     }
   else
     {
      ObjectSetInteger(0, name, OBJPROP_TIME,  0, t1);
      ObjectSetDouble (0, name, OBJPROP_PRICE, 0, top);
      ObjectSetInteger(0, name, OBJPROP_TIME,  1, t2);
      ObjectSetDouble (0, name, OBJPROP_PRICE, 1, bot);
     }
  }

// Draw / extend an MSS entry zone (FVG or OB).
// t1 must be the zone's original creation time, stored in MSSZone.t1.
void DrawMSSZoneBox(const string &name, double top, double bot,
                    datetime t1, datetime t2, bool isFVG, bool isBull)
  {
   if(!InpShowMSSZones) return;
   color base = isFVG ? InpFVGColor : InpOBColor;
   color dim  = (color)(((int)(((base >> 16) & 0xFF) * 0.30) << 16) |
                        ((int)(((base >>  8) & 0xFF) * 0.30) <<  8) |
                         (int)((base & 0xFF) * 0.30));

   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, top, t2, bot);
      ObjectSetInteger(0, name, OBJPROP_COLOR,       base);
      ObjectSetInteger(0, name, OBJPROP_BGCOLOR,     dim);
      ObjectSetInteger(0, name, OBJPROP_FILL,        true);
      ObjectSetInteger(0, name, OBJPROP_BACK,        false);
      ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE,  false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN,      true);
      string tag = isFVG ? (isBull ? "FVG-B" : "FVG-S") : (isBull ? "OB-B" : "OB-S");
      ObjectSetString (0, name, OBJPROP_TEXT, tag);
     }
   else
     {
      // Only update the right edge — t1 (left edge) is fixed at creation time
      ObjectSetInteger(0, name, OBJPROP_TIME, 1, t2);
     }
  }

void DrawChochLabel(const string &name, const string &txt,
                    datetime t, double price, color col, bool above)
  {
   if(!InpShowMSSLabel || ObjectFind(0, name) >= 0) return;
   ObjectCreate(0, name, OBJ_TEXT, 0, t, price);
   ObjectSetString (0, name, OBJPROP_TEXT,       txt);
   ObjectSetInteger(0, name, OBJPROP_COLOR,      col);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR,     above ? ANCHOR_LOWER : ANCHOR_UPPER);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE,   8);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN,     true);
  }

// ================================================================
// HELPERS : level array
// ================================================================
void AddLevel(double price, double top, double bot,
              datetime t1, bool isHigh,
              const string &ln, const string &bx)
  {
   ArrayResize(g_lv, g_nLv + 1);
   g_lv[g_nLv].price    = price;
   g_lv[g_nLv].boxTop   = top;
   g_lv[g_nLv].boxBot   = bot;
   g_lv[g_nLv].t1       = t1;
   g_lv[g_nLv].isHigh   = isHigh;
   g_lv[g_nLv].lineName = ln;
   g_lv[g_nLv].boxName  = bx;
   g_nLv++;
  }

void RemoveLevel(int i)
  {
   if(i < 0 || i >= g_nLv) return;
   ObjectDelete(0, g_lv[i].lineName);
   ObjectDelete(0, g_lv[i].boxName);
   g_lv[i] = g_lv[g_nLv - 1];
   g_nLv--;
   ArrayResize(g_lv, g_nLv);
  }

// ================================================================
// HELPERS : reset
// ================================================================
void ResetAll()
  {
   ObjectsDeleteAll(0, PFX);
   ArrayResize(g_lv,   0); g_nLv = 0;
   ArrayResize(g_swHi, 0); g_nSH = 0;
   ArrayResize(g_swLo, 0); g_nSL = 0;
   g_lastPH = g_lastPL = 0;
   g_lastPHBar = g_lastPLBar = -1;
   g_trend = 0;
   g_nMSSZones  = 0;
   g_mssSL      = 0;
   g_lastBuyAlertBar  = -1;
   g_lastSellAlertBar = -1;
   g_lastMSSAlertBar  = -1;
   g_chochBar         = -1;
   g_chochSeq         = 0;
   g_lastExtTime      = 0;
  }

// ================================================================
// MSS ZONE DETECTION
// Scans the CHoCH breakout leg for FVGs and the Order Block.
//
//  legStart : bar index of the pivot that was broken (old HL or LH)
//  legEnd   : bar index of the CHoCH pivot (new LL or HH)
//  isBullLeg: true  = bullish leg (bear→bull CHoCH) → bullish FVG/OB
//             false = bearish leg (bull→bear CHoCH) → bearish FVG/OB
// ================================================================
void FindMSSZones(int legStart, int legEnd, bool isBullLeg,
                  const double &h[], const double &l[],
                  const double &o[], const double &c[],
                  const datetime &time[], int total, int chochSeq)
  {
   // Clear previous CHoCH zones from chart and array
   for(int z = 0; z < g_nMSSZones; z++)
      ObjectDelete(0, g_mssZones[z].boxName);
   g_nMSSZones = 0;

   if(legStart < 0 || legEnd <= legStart || legEnd >= total) return;

   string seq = IntegerToString(chochSeq);

   // ── 1. FVGs in the leg ─────────────────────────────────────────
   // Bearish FVG: l[i-1] > h[i+1]  → zone = [h[i+1], l[i-1]]  (resistance)
   // Bullish FVG: h[i-1] < l[i+1]  → zone = [h[i-1], l[i+1]]  (support)
   int fvgCount = 0;
   for(int i = legStart + 1; i <= legEnd - 1 && fvgCount < 4; i++)
     {
      if(!isBullLeg && l[i - 1] > h[i + 1])
        {
         double zTop = l[i - 1], zBot = h[i + 1];
         if(zTop > zBot && g_nMSSZones < 8)
           {
            string bn = PFX + "MZ_FVG_" + seq + "_" + IntegerToString(i);
            g_mssZones[g_nMSSZones].top     = zTop;
            g_mssZones[g_nMSSZones].bot     = zBot;
            g_mssZones[g_nMSSZones].t1      = time[i];   // store creation time
            g_mssZones[g_nMSSZones].isFVG   = true;
            g_mssZones[g_nMSSZones].isBull  = false;
            g_mssZones[g_nMSSZones].active  = true;
            g_mssZones[g_nMSSZones].boxName = bn;
            DrawMSSZoneBox(bn, zTop, zBot, time[i], time[legEnd], true, false);
            g_nMSSZones++; fvgCount++;
           }
        }
      else if(isBullLeg && h[i - 1] < l[i + 1])
        {
         double zTop = l[i + 1], zBot = h[i - 1];
         if(zTop > zBot && g_nMSSZones < 8)
           {
            string bn = PFX + "MZ_FVG_" + seq + "_" + IntegerToString(i);
            g_mssZones[g_nMSSZones].top     = zTop;
            g_mssZones[g_nMSSZones].bot     = zBot;
            g_mssZones[g_nMSSZones].t1      = time[i];   // store creation time
            g_mssZones[g_nMSSZones].isFVG   = true;
            g_mssZones[g_nMSSZones].isBull  = true;
            g_mssZones[g_nMSSZones].active  = true;
            g_mssZones[g_nMSSZones].boxName = bn;
            DrawMSSZoneBox(bn, zTop, zBot, time[i], time[legEnd], true, true);
            g_nMSSZones++; fvgCount++;
           }
        }
     }

   // ── 2. Order Block (most recent opposite candle in the leg) ─────
   // Bearish OB: last bullish candle (c>o) in a bearish leg  → resistance
   // Bullish OB: last bearish candle (c<o) in a bullish leg  → support
   for(int i = legEnd - 1; i >= legStart && g_nMSSZones < 8; i--)
     {
      bool isBullCandle = (c[i] > o[i]);
      bool isBearCandle = (c[i] < o[i]);
      bool isOB = (!isBullLeg && isBullCandle) || (isBullLeg && isBearCandle);
      if(isOB)
        {
         double zTop = isBullCandle ? c[i] : o[i];
         double zBot = isBullCandle ? o[i] : c[i];
         if(zTop > zBot)
           {
            string bn = PFX + "MZ_OB_" + seq + "_" + IntegerToString(i);
            g_mssZones[g_nMSSZones].top     = zTop;
            g_mssZones[g_nMSSZones].bot     = zBot;
            g_mssZones[g_nMSSZones].t1      = time[i];   // store creation time
            g_mssZones[g_nMSSZones].isFVG   = false;
            g_mssZones[g_nMSSZones].isBull  = isBullLeg;
            g_mssZones[g_nMSSZones].active  = true;
            g_mssZones[g_nMSSZones].boxName = bn;
            DrawMSSZoneBox(bn, zTop, zBot, time[i], time[legEnd], false, isBullLeg);
            g_nMSSZones++;
           }
         break;
        }
     }
  }

// ================================================================
// OnCalculate
// ================================================================
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
   if(rates_total < InpSwingLeft + InpSwingRight + 1) return prev_calculated;

   if(prev_calculated == 0)
     {
      ResetAll();
      // BufPivHProc / BufPivLProc are auto-initialised to 0 by MT5 on full recalc
      ArrayInitialize(BufBuyBull,  0);
      ArrayInitialize(BufBuyCT,    0);
      ArrayInitialize(BufBuyMSS,   0);
      ArrayInitialize(BufSellBear, 0);
      ArrayInitialize(BufSellCT,   0);
      ArrayInitialize(BufSellMSS,  0);
     }

   int startBar = (prev_calculated == 0)
                  ? InpSwingLeft
                  : MathMax(InpSwingLeft, prev_calculated - InpSwingRight - 1);

   datetime tNow   = time[rates_total - 1];
   double   bw1    = 0.001 * InpBoxWidth;
   bool     isLive = (prev_calculated > 0);

   // ================================================================
   // MAIN BAR LOOP  (oldest → newest)
   // ================================================================
   for(int i = startBar; i < rates_total; i++)
     {
      int pBar = i - InpSwingRight;
      if(pBar < InpSwingLeft) continue;

      bool newPH = IsPivotHigh(high, pBar, InpSwingLeft, InpSwingRight, rates_total);
      bool newPL = IsPivotLow (low,  pBar, InpSwingLeft, InpSwingRight, rates_total);

      // ── NEW PIVOT HIGH ──────────────────────────────────────────
      // BufPivHProc[pBar] == 0 means this bar has never been processed.
      // Set it to 1 on first visit so incremental runs skip it — this
      // prevents CHoCH bars (which write to no signal buffer) from being
      // re-classified as LH signals on subsequent ticks.
      if(newPH && BufPivHProc[pBar] == 0.0)
        {
         BufPivHProc[pBar] = 1.0;   // mark as processed FIRST

         double ph = high[pBar];

         // Draw liquidity line + box
         string ln = PFX + "LH_" + IntegerToString(pBar);
         string bx = PFX + "BH_" + IntegerToString(pBar);
         DrawLine(ln, ph, time[pBar], time[i], InpHighColor);
         DrawBox (bx, ph * (1.0 + bw1), ph, time[pBar], time[i], InpHighColor);
         AddLevel(ph, ph * (1.0 + bw1), ph, time[pBar], true, ln, bx);

         // Capture prior trend before any update (fixes withTrend ordering bug)
         int priorTrend = g_trend;
         bool isHH = (g_lastPH == 0 || ph > g_lastPH);

         if(isHH && priorTrend == -1)
           {
            // ─── CHoCH: bear → bull ────────────────────────────
            g_chochSeq++;
            DrawChochLabel(PFX + "CHoCH_" + IntegerToString(pBar),
                           "CHoCH", time[pBar], ph, InpMSSBullCol, false);
            int legStart = (g_lastPHBar >= 0) ? g_lastPHBar : MathMax(0, pBar - 30);
            FindMSSZones(legStart, pBar, true,
                         high, low, open, close, time, rates_total, g_chochSeq);
            // FIX: SL for BUY MSS = last swing LOW (structural support below zones)
            g_mssSL    = (g_lastPL > 0) ? g_lastPL : ph * 0.999;
            g_mssBull  = true;
            g_trend    = 1;
            g_chochBar = i;
           }
         else if(isHH)
           {
            g_trend = (g_trend == 0) ? 1 : g_trend;
           }
         else
           {
            // LH → SELL signal
            // Trend does NOT flip on a single LH — only CHoCH flips trend.
            bool withTrend = (priorTrend == -1);

            double tp1, tp2, tp3;
            FindSellTPs(ph, tp1, tp2, tp3);
            // SL = previous structural High (above entry); fallback if no prior PH yet
            double sl = (g_lastPH > ph) ? g_lastPH : ph * 1.001;

            if(withTrend)
              {
               BufSellBear[pBar] = ph;
               FireSignal("SELL", "Bear", ph, sl,
                          tp1, tp2, tp3, i,
                          isLive && i == rates_total - 1,
                          g_lastSellAlertBar);
              }
            else if(InpShowCTSig)
              {
               BufSellCT[pBar] = ph;
               FireSignal("SELL", "Bull", ph, sl,
                          tp1, tp2, tp3, i,
                          isLive && i == rates_total - 1,
                          g_lastSellAlertBar);
              }
           }

         AddSwingHigh(ph);
         g_lastPH = ph;  g_lastPHBar = pBar;
        }

      // ── NEW PIVOT LOW ───────────────────────────────────────────
      if(newPL && BufPivLProc[pBar] == 0.0)
        {
         BufPivLProc[pBar] = 1.0;   // mark as processed FIRST

         double pl = low[pBar];

         string ln = PFX + "LL_" + IntegerToString(pBar);
         string bx = PFX + "BL_" + IntegerToString(pBar);
         DrawLine(ln, pl, time[pBar], time[i], InpLowColor);
         DrawBox (bx, pl, pl * (1.0 - bw1), time[pBar], time[i], InpLowColor);
         AddLevel(pl, pl, pl * (1.0 - bw1), time[pBar], false, ln, bx);

         int  priorTrend = g_trend;
         bool isLL = (g_lastPL == 0 || pl < g_lastPL);

         if(isLL && priorTrend == 1)
           {
            // ─── CHoCH: bull → bear ────────────────────────────
            g_chochSeq++;
            DrawChochLabel(PFX + "CHoCH_" + IntegerToString(pBar),
                           "CHoCH", time[pBar], pl, InpMSSBearCol, true);
            int legStart = (g_lastPLBar >= 0) ? g_lastPLBar : MathMax(0, pBar - 30);
            FindMSSZones(legStart, pBar, false,
                         high, low, open, close, time, rates_total, g_chochSeq);
            // FIX: SL for SELL MSS = last swing HIGH (structural resistance above zones)
            g_mssSL    = (g_lastPH > 0) ? g_lastPH : pl * 1.001;
            g_mssBull  = false;
            g_trend    = -1;
            g_chochBar = i;
           }
         else if(isLL)
           {
            g_trend = (g_trend == 0) ? -1 : g_trend;
           }
         else
           {
            // HL → BUY signal
            // Trend does NOT flip on a single HL — only CHoCH flips trend.
            bool withTrend = (priorTrend == 1);

            double tp1, tp2, tp3;
            FindBuyTPs(pl, tp1, tp2, tp3);
            // SL = previous structural Low (below entry); fallback if no prior PL yet
            double sl = (g_lastPL > 0 && g_lastPL < pl) ? g_lastPL : pl * 0.999;

            if(withTrend)
              {
               BufBuyBull[pBar] = pl;
               FireSignal("BUY", "Bull", pl, sl,
                          tp1, tp2, tp3, i,
                          isLive && i == rates_total - 1,
                          g_lastBuyAlertBar);
              }
            else if(InpShowCTSig)
              {
               BufBuyCT[pBar] = pl;
               FireSignal("BUY", "Bear", pl, sl,
                          tp1, tp2, tp3, i,
                          isLive && i == rates_total - 1,
                          g_lastBuyAlertBar);
              }
           }

         AddSwingLow(pl);
         g_lastPL = pl;  g_lastPLBar = pBar;
        }

      // ── MSS ZONE ENTRY CHECK ────────────────────────────────────
      // Skip on the exact bar where a CHoCH fired (g_chochBar) to avoid
      // entering the breakout candle as an MSS trade.
      if(g_nMSSZones > 0 && i != g_chochBar)
        {
         for(int z = 0; z < g_nMSSZones; z++)
           {
            if(!g_mssZones[z].active) continue;

            bool entered   = false;
            double entryPx = 0.0;

            if(g_mssBull)
              {
               // BUY: price pulls back down into a bullish zone
               // Condition: low touches or enters zone top, high confirms bar is near zone
               if(low[i] <= g_mssZones[z].top && low[i] >= g_mssZones[z].bot)
                 { entered = true; entryPx = g_mssZones[z].top; }
              }
            else
              {
               // SELL: price retraces up into a bearish zone
               if(high[i] >= g_mssZones[z].bot && high[i] <= g_mssZones[z].top)
                 { entered = true; entryPx = g_mssZones[z].bot; }
              }

            if(entered && BufBuyMSS[i] == 0.0 && BufSellMSS[i] == 0.0)
              {
               string zType = g_mssZones[z].isFVG ? "MSS-FVG" : "MSS-OB";
               double tp1, tp2, tp3;

               if(g_mssBull)
                 {
                  BufBuyMSS[i] = entryPx;
                  FindBuyTPs(entryPx, tp1, tp2, tp3);
                  FireSignal("BUY", zType, entryPx, g_mssSL,
                             tp1, tp2, tp3, i,
                             isLive && i == rates_total - 1,
                             g_lastMSSAlertBar);
                 }
               else
                 {
                  BufSellMSS[i] = entryPx;
                  FindSellTPs(entryPx, tp1, tp2, tp3);
                  FireSignal("SELL", zType, entryPx, g_mssSL,
                             tp1, tp2, tp3, i,
                             isLive && i == rates_total - 1,
                             g_lastMSSAlertBar);
                 }

               g_mssZones[z].active = false;
              }
           }
        }

      // ── EXTEND ACTIVE ZONES & LEVELS (once per new bar, not per tick) ─
      if(i == rates_total - 1 && tNow != g_lastExtTime)
        {
         g_lastExtTime = tNow;

         // MSS zones — use stored t1, only update right edge
         for(int z = 0; z < g_nMSSZones; z++)
            if(g_mssZones[z].active)
               DrawMSSZoneBox(g_mssZones[z].boxName,
                              g_mssZones[z].top, g_mssZones[z].bot,
                              g_mssZones[z].t1, tNow,
                              g_mssZones[z].isFVG, g_mssZones[z].isBull);

         // Liquidity levels
         int j = 0;
         while(j < g_nLv)
           {
            double lp     = g_lv[j].price;
            bool   filled = (high[i] >= lp && low[i] <= lp);
            color  col    = g_lv[j].isHigh ? InpHighColor : InpLowColor;

            if(filled && InpHideFilled)
              { RemoveLevel(j); continue; }

            if(filled && InpExtendFill)
              {
               ObjectDelete(0, g_lv[j].lineName);
               ObjectDelete(0, g_lv[j].boxName);
               g_lv[j] = g_lv[g_nLv - 1];
               g_nLv--;
               ArrayResize(g_lv, g_nLv);
               continue;
              }

            if(!InpExtendFill) { j++; continue; }

            DrawLine(g_lv[j].lineName, lp, g_lv[j].t1, tNow, col);
            DrawBox (g_lv[j].boxName, g_lv[j].boxTop, g_lv[j].boxBot,
                     g_lv[j].t1, tNow, col);

            if(g_nLv >= MAX_OBJECTS) RemoveLevel(0);
            j++;
           }
        }
     }

   return rates_total;
  }
//+------------------------------------------------------------------+
