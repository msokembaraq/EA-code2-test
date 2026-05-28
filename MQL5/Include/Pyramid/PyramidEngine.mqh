//+------------------------------------------------------------------+
//|                                              PyramidEngine.mqh  |
//|          CPyramidEngine – backward-layering zone entry          |
//|                                                                  |
//| Layer 1 (probe, smallest lot) opens at zone edge on signal.     |
//| Layer 2 and 3 open when price moves DEEPER into the zone,       |
//| giving better entry prices and improving average cost.          |
//| All layers share one unified SL at zone bottom.                 |
//| SL hit = zone failed → main EA marks zone dead.                 |
//+------------------------------------------------------------------+
#property copyright "bidiisStrategy"
#property version   "2.00"

#include <Trade\Trade.mqh>
#include <Pyramid\PyramidUtils.mqh>

//+------------------------------------------------------------------+
struct SPyramidState
{
    ulong   ticket_initial;
    ulong   ticket_addon1;
    ulong   ticket_addon2;
    double  entry_price;       // layer 1 fill price
    double  unified_stop;      // zone-bottom SL, shared by all layers
    double  addon1_price;      // absolute price trigger for layer 2 (0 = disabled)
    double  addon2_price;      // absolute price trigger for layer 3 (0 = disabled)
    long    direction;
    bool    addon1_open;
    bool    addon2_open;
    bool    active;
};

//+------------------------------------------------------------------+
class CPyramidEngine
{
private:
    CTrade          m_trade;
    SPyramidState   m_state;

    ulong           m_magic;
    int             m_slippage;
    double          m_lot_initial;   // probe (smallest) — enters at zone edge
    double          m_lot_addon1;    // mid lot
    double          m_lot_addon2;    // largest lot — best price, deepest in zone
    bool            m_trail_after_full;
    double          m_trail_pips;
    double          m_trail_step_pips;
    bool            m_initialized;
    bool            m_sl_needs_retry;
    datetime        m_last_trail_bar;
    bool            m_closed_by_sl;  // true when last pyramid closed via SL hit

    void            ResetState();
    bool            ModifyAllStops(double new_stop);
    bool            PositionStillOpen(ulong ticket);
    ulong           GetTicketFromLastDeal();

public:
                    CPyramidEngine();
                   ~CPyramidEngine() {}

    bool            Init(ulong magic, int slippage,
                         double lot_initial, double lot_addon1, double lot_addon2,
                         bool trail_after_full, double trail_pips, double trail_step_pips);

    // addon1_price / addon2_price: absolute price levels computed by main EA
    // using zone width × depth %. Pass 0 to disable a layer (zone too narrow).
    bool            OpenInitial(ENUM_POSITION_TYPE direction,
                                double stop_loss,
                                double addon1_price, double addon2_price,
                                string comment = "SR_L1");

    void            Manage();
    void            HandleTransaction(const MqlTradeTransaction &trans);
    void            RecoverState();
    bool            IsActive()        { return m_state.active; }
    SPyramidState   GetState()        { return m_state; }
    void            ClosePyramid();
    bool            WasClosedBySL()   { return m_closed_by_sl; }
    void            ClearSLFlag()     { m_closed_by_sl = false; }
};

//+------------------------------------------------------------------+
CPyramidEngine::CPyramidEngine()
{
    m_initialized    = false;
    m_sl_needs_retry = false;
    m_last_trail_bar = 0;
    m_closed_by_sl   = false;
    ResetState();
}

//+------------------------------------------------------------------+
void CPyramidEngine::ResetState()
{
    m_state.ticket_initial = 0;
    m_state.ticket_addon1  = 0;
    m_state.ticket_addon2  = 0;
    m_state.entry_price    = 0.0;
    m_state.unified_stop   = 0.0;
    m_state.addon1_price   = 0.0;
    m_state.addon2_price   = 0.0;
    m_state.direction      = -1;
    m_state.addon1_open    = false;
    m_state.addon2_open    = false;
    m_state.active         = false;
    m_sl_needs_retry       = false;
}

//+------------------------------------------------------------------+
bool CPyramidEngine::Init(ulong magic, int slippage,
                           double lot_initial, double lot_addon1, double lot_addon2,
                           bool trail_after_full, double trail_pips, double trail_step_pips)
{
    if(!IsHedgingAccount())
    {
        Print("PyramidEngine: Requires a retail hedging account.");
        return false;
    }
    if(lot_initial <= 0 || lot_addon1 <= 0 || lot_addon2 <= 0)
    {
        Print("PyramidEngine: All lot sizes must be > 0.");
        return false;
    }

    m_magic             = magic;
    m_slippage          = slippage;
    m_lot_initial       = lot_initial;
    m_lot_addon1        = lot_addon1;
    m_lot_addon2        = lot_addon2;
    m_trail_after_full  = trail_after_full;
    m_trail_pips        = trail_pips;
    m_trail_step_pips   = trail_step_pips;
    m_sl_needs_retry    = false;
    m_closed_by_sl      = false;

    m_trade.SetExpertMagicNumber(magic);
    m_trade.SetDeviationInPoints(slippage);

    m_initialized = true;
    return true;
}

//+------------------------------------------------------------------+
bool CPyramidEngine::OpenInitial(ENUM_POSITION_TYPE direction,
                                  double stop_loss,
                                  double addon1_price, double addon2_price,
                                  string comment)
{
    if(!m_initialized || m_state.active) return false;

    double price = (direction == POSITION_TYPE_BUY)
                   ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                   : SymbolInfoDouble(_Symbol, SYMBOL_BID);

    bool res = (direction == POSITION_TYPE_BUY)
               ? m_trade.Buy (m_lot_initial, _Symbol, price, stop_loss, 0, comment)
               : m_trade.Sell(m_lot_initial, _Symbol, price, stop_loss, 0, comment);

    if(!res)
    {
        Print("PyramidEngine: OpenInitial failed. Err=", GetLastError());
        return false;
    }

    ulong ticket = GetTicketFromLastDeal();
    if(ticket == 0)
    {
        Print("PyramidEngine: Could not retrieve ticket from last deal.");
        return false;
    }

    m_state.ticket_initial = ticket;
    m_state.entry_price    = price;
    m_state.unified_stop   = stop_loss;
    m_state.addon1_price   = addon1_price;
    m_state.addon2_price   = addon2_price;
    m_state.direction      = (long)direction;
    m_state.addon1_open    = false;
    m_state.addon2_open    = false;
    m_state.active         = true;
    m_closed_by_sl         = false;

    PrintFormat("PyramidEngine: L1 opened. Ticket=%I64u Dir=%s SL=%.5f L2@%.5f L3@%.5f",
                ticket,
                direction == POSITION_TYPE_BUY ? "BUY" : "SELL",
                stop_loss,
                addon1_price > 0 ? addon1_price : 0.0,
                addon2_price > 0 ? addon2_price : 0.0);
    return true;
}

//+------------------------------------------------------------------+
ulong CPyramidEngine::GetTicketFromLastDeal()
{
    ulong deal = m_trade.ResultDeal();
    if(deal == 0)
    {
        Print("PyramidEngine: ResultDeal()=0 – no deal from last request.");
        return 0;
    }

    HistorySelect(TimeCurrent() - 60, TimeCurrent() + 1);

    if(!HistoryDealSelect(deal))
    {
        Print("PyramidEngine: HistoryDealSelect failed for deal=", deal);
        for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
            ulong ticket = PositionGetTicket(i);
            if(!PositionSelectByTicket(ticket)) continue;
            if(PositionGetInteger(POSITION_MAGIC) != (long)m_magic) continue;
            if(PositionGetString(POSITION_SYMBOL) != _Symbol)        continue;
            Print("PyramidEngine: Ticket recovered via position scan. Ticket=", ticket);
            return ticket;
        }
        return 0;
    }
    return (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID);
}

//+------------------------------------------------------------------+
bool CPyramidEngine::PositionStillOpen(ulong ticket)
{
    return (ticket > 0 && PositionSelectByTicket(ticket));
}

//+------------------------------------------------------------------+
bool CPyramidEngine::ModifyAllStops(double new_stop)
{
    ENUM_ORDER_TYPE chk = (m_state.direction == POSITION_TYPE_BUY)
                          ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
    if(!IsStopLevelValid(_Symbol, new_stop, chk))
    {
        PrintFormat("PyramidEngine: new_stop=%.5f rejected – inside broker minimum stop distance.", new_stop);
        return false;
    }

    bool ok = true;

    if(PositionStillOpen(m_state.ticket_initial))
        if(!m_trade.PositionModify(m_state.ticket_initial, new_stop, 0)) ok = false;

    if(m_state.addon1_open && PositionStillOpen(m_state.ticket_addon1))
        if(!m_trade.PositionModify(m_state.ticket_addon1, new_stop, 0)) ok = false;

    if(m_state.addon2_open && PositionStillOpen(m_state.ticket_addon2))
        if(!m_trade.PositionModify(m_state.ticket_addon2, new_stop, 0)) ok = false;

    if(ok) m_state.unified_stop = new_stop;
    return ok;
}

//+------------------------------------------------------------------+
void CPyramidEngine::Manage()
{
    if(!m_initialized || !m_state.active) return;

    bool init_alive   = PositionStillOpen(m_state.ticket_initial);
    bool addon1_alive = m_state.addon1_open && PositionStillOpen(m_state.ticket_addon1);
    bool addon2_alive = m_state.addon2_open && PositionStillOpen(m_state.ticket_addon2);

    if(m_state.addon1_open && !addon1_alive) m_state.addon1_open = false;
    if(m_state.addon2_open && !addon2_alive) m_state.addon2_open = false;

    if(!init_alive && !addon1_alive && !addon2_alive)
    {
        Print("PyramidEngine: All positions closed. Resetting.");
        ResetState();
        return;
    }

    // SL sync retry
    if(m_sl_needs_retry && m_state.unified_stop > 0)
    {
        ENUM_ORDER_TYPE chk = (m_state.direction == POSITION_TYPE_BUY)
                              ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
        if(IsStopLevelValid(_Symbol, m_state.unified_stop, chk))
        {
            bool retry_ok = true;
            if(init_alive && PositionSelectByTicket(m_state.ticket_initial) &&
               MathAbs(PositionGetDouble(POSITION_SL) - m_state.unified_stop) > _Point)
                if(!m_trade.PositionModify(m_state.ticket_initial, m_state.unified_stop, 0))
                    retry_ok = false;
            if(addon1_alive && PositionSelectByTicket(m_state.ticket_addon1) &&
               MathAbs(PositionGetDouble(POSITION_SL) - m_state.unified_stop) > _Point)
                if(!m_trade.PositionModify(m_state.ticket_addon1, m_state.unified_stop, 0))
                    retry_ok = false;
            if(addon2_alive && PositionSelectByTicket(m_state.ticket_addon2) &&
               MathAbs(PositionGetDouble(POSITION_SL) - m_state.unified_stop) > _Point)
                if(!m_trade.PositionModify(m_state.ticket_addon2, m_state.unified_stop, 0))
                    retry_ok = false;
            if(retry_ok)
            {
                Print("PyramidEngine: SL retry succeeded. UnifiedSL=", m_state.unified_stop);
                m_sl_needs_retry = false;
            }
        }
    }

    double pip = GetPipSize(_Symbol);
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    bool   isBuy = (m_state.direction == POSITION_TYPE_BUY);

    // Layer 2 trigger: price moves deeper into zone (lower for buy, higher for sell)
    if(!m_state.addon1_open && m_state.addon1_price > 0)
    {
        bool triggered = isBuy ? (bid <= m_state.addon1_price)
                                : (ask >= m_state.addon1_price);
        if(triggered)
        {
            double fillPrice = isBuy ? ask : bid;
            string cmt       = "SR_L2";
            bool opened = isBuy ? m_trade.Buy (m_lot_addon1, _Symbol, fillPrice, m_state.unified_stop, 0, cmt)
                                : m_trade.Sell(m_lot_addon1, _Symbol, fillPrice, m_state.unified_stop, 0, cmt);
            if(opened)
            {
                ulong ticket = GetTicketFromLastDeal();
                if(ticket > 0)
                {
                    m_state.ticket_addon1 = ticket;
                    m_state.addon1_open   = true;
                    // SL is already set correctly at open — sync all to be safe
                    if(!ModifyAllStops(m_state.unified_stop))
                        m_sl_needs_retry = true;
                    else
                        Print("PyramidEngine: L2 opened. Ticket=", ticket,
                              " Entry=", fillPrice, " SL=", m_state.unified_stop);
                    return;
                }
            }
            else
                Print("PyramidEngine: L2 open failed. Err=", GetLastError());
        }
    }

    // Layer 3 trigger: requires layer 2 to be open first
    if(m_state.addon1_open && !m_state.addon2_open && m_state.addon2_price > 0)
    {
        bool triggered = isBuy ? (bid <= m_state.addon2_price)
                                : (ask >= m_state.addon2_price);
        if(triggered)
        {
            double fillPrice = isBuy ? ask : bid;
            string cmt       = "SR_L3";
            bool opened = isBuy ? m_trade.Buy (m_lot_addon2, _Symbol, fillPrice, m_state.unified_stop, 0, cmt)
                                : m_trade.Sell(m_lot_addon2, _Symbol, fillPrice, m_state.unified_stop, 0, cmt);
            if(opened)
            {
                ulong ticket = GetTicketFromLastDeal();
                if(ticket > 0)
                {
                    m_state.ticket_addon2 = ticket;
                    m_state.addon2_open   = true;
                    if(!ModifyAllStops(m_state.unified_stop))
                        m_sl_needs_retry = true;
                    else
                        Print("PyramidEngine: L3 opened. Ticket=", ticket,
                              " Entry=", fillPrice, " SL=", m_state.unified_stop);
                }
            }
            else
                Print("PyramidEngine: L3 open failed. Err=", GetLastError());
        }
    }

    // Trailing — starts when all available layers are filled
    // If addon2_price=0 (layer 3 disabled): trail after layer 2 fills
    // If both valid: trail after layer 3 fills
    bool allLayersFilled = m_state.addon1_open &&
                           (m_state.addon2_price <= 0 || m_state.addon2_open);

    if(m_trail_after_full && allLayersFilled)
    {
        datetime bar_time = iTime(_Symbol, _Period, 0);
        if(bar_time != m_last_trail_bar)
        {
            m_last_trail_bar = bar_time;

            double trail_dist = m_trail_pips      * pip;
            double trail_step = m_trail_step_pips * pip;

            if(isBuy)
            {
                double candidate = NormalizeDouble(bid - trail_dist, _Digits);
                if(candidate > m_state.unified_stop + trail_step)
                {
                    if(!ModifyAllStops(candidate))
                    {
                        m_state.unified_stop = candidate;
                        m_sl_needs_retry     = true;
                    }
                }
            }
            else
            {
                double candidate = NormalizeDouble(ask + trail_dist, _Digits);
                if(candidate < m_state.unified_stop - trail_step)
                {
                    if(!ModifyAllStops(candidate))
                    {
                        m_state.unified_stop = candidate;
                        m_sl_needs_retry     = true;
                    }
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
void CPyramidEngine::HandleTransaction(const MqlTradeTransaction &trans)
{
    if(!m_state.active) return;
    if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;

    // Detect SL close for any layer in this pyramid
    bool ours = (trans.position == m_state.ticket_initial) ||
                (m_state.addon1_open && trans.position == m_state.ticket_addon1) ||
                (m_state.addon2_open && trans.position == m_state.ticket_addon2);
    bool isClose = (m_state.direction == POSITION_TYPE_BUY)
                   ? (trans.deal_type == DEAL_TYPE_SELL)
                   : (trans.deal_type == DEAL_TYPE_BUY);

    if(ours && isClose)
    {
        HistorySelect(TimeCurrent() - 30, TimeCurrent() + 1);
        if(HistoryDealSelect(trans.deal))
        {
            ENUM_DEAL_REASON reason = (ENUM_DEAL_REASON)HistoryDealGetInteger(trans.deal, DEAL_REASON);
            if(reason == DEAL_REASON_SL)
                m_closed_by_sl = true;
        }
    }

    // If initial position closed, cascade-close any open layers
    bool is_initial_close = (trans.position == m_state.ticket_initial) && isClose;
    if(is_initial_close)
    {
        if(m_state.addon1_open && PositionStillOpen(m_state.ticket_addon1))
            m_trade.PositionClose(m_state.ticket_addon1);
        if(m_state.addon2_open && PositionStillOpen(m_state.ticket_addon2))
            m_trade.PositionClose(m_state.ticket_addon2);
        ResetState();
    }
}

//+------------------------------------------------------------------+
void CPyramidEngine::ClosePyramid()
{
    if(!m_state.active) return;
    if(PositionStillOpen(m_state.ticket_initial))
        m_trade.PositionClose(m_state.ticket_initial);
    if(m_state.addon1_open && PositionStillOpen(m_state.ticket_addon1))
        m_trade.PositionClose(m_state.ticket_addon1);
    if(m_state.addon2_open && PositionStillOpen(m_state.ticket_addon2))
        m_trade.PositionClose(m_state.ticket_addon2);
    Print("PyramidEngine: ClosePyramid – all positions closed.");
    ResetState();
}

//+------------------------------------------------------------------+
void CPyramidEngine::RecoverState()
{
    if(!m_initialized) return;

    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(!PositionSelectByTicket(ticket)) continue;
        if(PositionGetInteger(POSITION_MAGIC)  != (long)m_magic)  continue;
        if(PositionGetString(POSITION_SYMBOL)  != _Symbol)        continue;

        string comment = PositionGetString(POSITION_COMMENT);
        long   dir     = PositionGetInteger(POSITION_TYPE);
        double sl      = PositionGetDouble(POSITION_SL);
        double open_p  = PositionGetDouble(POSITION_PRICE_OPEN);

        if(StringFind(comment, "L3") >= 0 || StringFind(comment, "Addon2") >= 0)
        {
            m_state.ticket_addon2 = ticket;
            m_state.addon2_open   = true;
        }
        else if(StringFind(comment, "L2") >= 0 || StringFind(comment, "Addon1") >= 0)
        {
            m_state.ticket_addon1 = ticket;
            m_state.addon1_open   = true;
        }
        else
        {
            m_state.ticket_initial = ticket;
            m_state.entry_price    = open_p;
            m_state.direction      = dir;
        }

        if(!m_state.active)
            m_state.unified_stop = sl;
        else if(dir == POSITION_TYPE_BUY)
            m_state.unified_stop = MathMax(m_state.unified_stop, sl);
        else
            m_state.unified_stop = MathMin(m_state.unified_stop, sl);
        m_state.active = true;
    }

    if(m_state.active)
        Print("PyramidEngine: Recovered. L2=", m_state.addon1_open, " L3=", m_state.addon2_open);
}
