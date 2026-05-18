//+------------------------------------------------------------------+
//|                                              PyramidEngine.mqh  |
//|                 CPyramidEngine – safe pyramiding into winners    |
//+------------------------------------------------------------------+
#property copyright "bidiisStrategy"
#property version   "1.00"

#include <Trade\Trade.mqh>
#include <Pyramid\PyramidUtils.mqh>

//+------------------------------------------------------------------+
//| Pyramid state (all positions in one pyramid)                     |
//+------------------------------------------------------------------+
struct SPyramidState
{
    ulong   ticket_initial;
    ulong   ticket_addon1;
    ulong   ticket_addon2;
    double  entry_price;
    double  unified_stop;
    long    direction;        // POSITION_TYPE_BUY or POSITION_TYPE_SELL
    bool    addon1_open;
    bool    addon2_open;
    bool    active;
};

//+------------------------------------------------------------------+
//| CPyramidEngine                                                   |
//+------------------------------------------------------------------+
class CPyramidEngine
{
private:
    CTrade          m_trade;
    SPyramidState   m_state;

    ulong           m_magic;
    int             m_slippage;
    double          m_lot_initial;
    double          m_lot_addon1;
    double          m_lot_addon2;
    double          m_addon1_trigger_pips;
    double          m_addon2_trigger_pips;
    double          m_stop_after_addon1_pips;
    double          m_stop_after_addon2_pips;
    bool            m_trail_after_full;
    double          m_trail_pips;
    double          m_trail_step_pips;
    bool            m_initialized;

    void            ResetState();
    bool            ModifyAllStops(double new_stop);
    bool            PositionStillOpen(ulong ticket);
    ulong           GetTicketFromLastDeal();

public:
                    CPyramidEngine();
                   ~CPyramidEngine() {}

    bool            Init(ulong magic, int slippage,
                         double lot_initial, double lot_addon1, double lot_addon2,
                         double addon1_trigger_pips, double addon2_trigger_pips,
                         double stop_after_addon1_pips, double stop_after_addon2_pips,
                         bool trail_after_full, double trail_pips, double trail_step_pips);

    bool            OpenInitial(ENUM_POSITION_TYPE direction, double price,
                                double stop_loss, double lot, string comment = "SR_Pyramid");
    void            Manage();
    void            HandleTransaction(const MqlTradeTransaction &trans);
    void            RecoverState();
    bool            IsActive()   { return m_state.active; }
    SPyramidState   GetState()   { return m_state; }
};

//+------------------------------------------------------------------+
CPyramidEngine::CPyramidEngine()
{
    m_initialized = false;
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
    m_state.direction      = -1;
    m_state.addon1_open    = false;
    m_state.addon2_open    = false;
    m_state.active         = false;
}

//+------------------------------------------------------------------+
bool CPyramidEngine::Init(ulong magic, int slippage,
                           double lot_initial, double lot_addon1, double lot_addon2,
                           double addon1_trigger_pips, double addon2_trigger_pips,
                           double stop_after_addon1_pips, double stop_after_addon2_pips,
                           bool trail_after_full, double trail_pips, double trail_step_pips)
{
    if(!IsHedgingAccount())
    {
        Print("PyramidEngine: Requires a retail hedging account.");
        return false;
    }

    if(lot_initial <= lot_addon1 || lot_addon1 <= lot_addon2)
    {
        Print("PyramidEngine: Lots must be strictly decreasing (initial > addon1 > addon2).");
        return false;
    }

    if(addon1_trigger_pips >= addon2_trigger_pips)
    {
        Print("PyramidEngine: Addon2 trigger must exceed Addon1 trigger.");
        return false;
    }

    m_magic                  = magic;
    m_slippage               = slippage;
    m_lot_initial            = lot_initial;
    m_lot_addon1             = lot_addon1;
    m_lot_addon2             = lot_addon2;
    m_addon1_trigger_pips    = addon1_trigger_pips;
    m_addon2_trigger_pips    = addon2_trigger_pips;
    m_stop_after_addon1_pips = stop_after_addon1_pips;
    m_stop_after_addon2_pips = stop_after_addon2_pips;
    m_trail_after_full       = trail_after_full;
    m_trail_pips             = trail_pips;
    m_trail_step_pips        = trail_step_pips;

    m_trade.SetExpertMagicNumber(magic);
    m_trade.SetDeviationInPoints(slippage);

    m_initialized = true;
    return true;
}

//+------------------------------------------------------------------+
bool CPyramidEngine::OpenInitial(ENUM_POSITION_TYPE direction, double price,
                                  double stop_loss, double lot, string comment)
{
    if(!m_initialized || m_state.active) return false;

    bool res = (direction == POSITION_TYPE_BUY)
               ? m_trade.Buy(lot, _Symbol, price, stop_loss, 0, comment)
               : m_trade.Sell(lot, _Symbol, price, stop_loss, 0, comment);

    if(!res)
    {
        Print("PyramidEngine: OpenInitial failed. Err=", GetLastError());
        return false;
    }

    Sleep(100);
    ulong ticket = GetTicketFromLastDeal();
    if(ticket == 0)
    {
        Print("PyramidEngine: Could not retrieve ticket from last deal.");
        return false;
    }

    m_state.ticket_initial = ticket;
    m_state.entry_price    = price;
    m_state.unified_stop   = stop_loss;
    m_state.direction      = (long)direction;
    m_state.addon1_open    = false;
    m_state.addon2_open    = false;
    m_state.active         = true;

    Print("PyramidEngine: Initial opened. Ticket=", ticket,
          " Dir=", (direction == POSITION_TYPE_BUY ? "BUY" : "SELL"),
          " SL=", stop_loss);
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

    // Load recent history so HistoryDealSelect can find the deal
    HistorySelect(TimeCurrent() - 60, TimeCurrent() + 1);

    if(!HistoryDealSelect(deal))
    {
        Print("PyramidEngine: HistoryDealSelect failed for deal=", deal);
        // Fallback: scan open positions for our magic number
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

    if(!init_alive && !addon1_alive && !addon2_alive)
    {
        Print("PyramidEngine: All positions closed. Resetting.");
        ResetState();
        return;
    }

    double pip     = GetPipSize(_Symbol);
    double bid     = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double ask     = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double current = (m_state.direction == POSITION_TYPE_BUY) ? bid : ask;

    double pips_gained = (m_state.direction == POSITION_TYPE_BUY)
                         ? (current - m_state.entry_price) / pip
                         : (m_state.entry_price - current) / pip;

    // Addon 1 trigger
    if(!m_state.addon1_open && pips_gained >= m_addon1_trigger_pips)
    {
        double price    = (m_state.direction == POSITION_TYPE_BUY) ? ask : bid;
        double new_stop = (m_state.direction == POSITION_TYPE_BUY)
                          ? m_state.entry_price + m_stop_after_addon1_pips * pip
                          : m_state.entry_price - m_stop_after_addon1_pips * pip;

        bool opened = (m_state.direction == POSITION_TYPE_BUY)
                      ? m_trade.Buy(m_lot_addon1, _Symbol, price, new_stop, 0, "SR_Addon1")
                      : m_trade.Sell(m_lot_addon1, _Symbol, price, new_stop, 0, "SR_Addon1");

        if(opened)
        {
            Sleep(100);
            ulong ticket = GetTicketFromLastDeal();
            if(ticket > 0)
            {
                m_state.ticket_addon1 = ticket;
                m_state.addon1_open   = true;
                ModifyAllStops(NormalizeDouble(new_stop, _Digits));
                Print("PyramidEngine: Addon1 opened. Ticket=", ticket, " NewSL=", new_stop);
                return; // gap-bar protection
            }
        }
        else
            Print("PyramidEngine: Addon1 failed. Err=", GetLastError());
    }

    // Addon 2 trigger
    if(m_state.addon1_open && !m_state.addon2_open && pips_gained >= m_addon2_trigger_pips)
    {
        double price    = (m_state.direction == POSITION_TYPE_BUY) ? ask : bid;
        double new_stop = (m_state.direction == POSITION_TYPE_BUY)
                          ? m_state.entry_price + m_stop_after_addon2_pips * pip
                          : m_state.entry_price - m_stop_after_addon2_pips * pip;

        bool opened = (m_state.direction == POSITION_TYPE_BUY)
                      ? m_trade.Buy(m_lot_addon2, _Symbol, price, new_stop, 0, "SR_Addon2")
                      : m_trade.Sell(m_lot_addon2, _Symbol, price, new_stop, 0, "SR_Addon2");

        if(opened)
        {
            Sleep(100);
            ulong ticket = GetTicketFromLastDeal();
            if(ticket > 0)
            {
                m_state.ticket_addon2 = ticket;
                m_state.addon2_open   = true;
                ModifyAllStops(NormalizeDouble(new_stop, _Digits));
                Print("PyramidEngine: Addon2 opened. Ticket=", ticket, " NewSL=", new_stop);
            }
        }
        else
            Print("PyramidEngine: Addon2 failed. Err=", GetLastError());
    }

    // Trailing stop after full pyramid
    if(m_trail_after_full && m_state.addon1_open && m_state.addon2_open)
    {
        double trail_dist = m_trail_pips      * pip;
        double trail_step = m_trail_step_pips * pip;

        if(m_state.direction == POSITION_TYPE_BUY)
        {
            double candidate = bid - trail_dist;
            if(candidate > m_state.unified_stop + trail_step)
                ModifyAllStops(NormalizeDouble(candidate, _Digits));
        }
        else
        {
            double candidate = ask + trail_dist;
            if(candidate < m_state.unified_stop - trail_step)
                ModifyAllStops(NormalizeDouble(candidate, _Digits));
        }
    }
}

//+------------------------------------------------------------------+
void CPyramidEngine::HandleTransaction(const MqlTradeTransaction &trans)
{
    if(!m_state.active) return;
    if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;

    bool is_initial_close =
        (trans.position == m_state.ticket_initial) &&
        ((trans.deal_type == DEAL_TYPE_SELL && m_state.direction == POSITION_TYPE_BUY) ||
         (trans.deal_type == DEAL_TYPE_BUY  && m_state.direction == POSITION_TYPE_SELL));

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
void CPyramidEngine::RecoverState()
{
    if(!m_initialized) return;

    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(!PositionSelectByTicket(ticket)) continue;
        if(PositionGetInteger(POSITION_MAGIC)  != (long)m_magic)  continue;
        if(PositionGetString(POSITION_SYMBOL)  != _Symbol)        continue;

        string comment  = PositionGetString(POSITION_COMMENT);
        long   dir      = PositionGetInteger(POSITION_TYPE);
        double sl       = PositionGetDouble(POSITION_SL);
        double open_p   = PositionGetDouble(POSITION_PRICE_OPEN);

        if(StringFind(comment, "Addon2") >= 0)
        {
            m_state.ticket_addon2 = ticket;
            m_state.addon2_open   = true;
        }
        else if(StringFind(comment, "Addon1") >= 0)
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

        m_state.unified_stop = sl;
        m_state.active       = true;
    }

    if(m_state.active)
        Print("PyramidEngine: Recovered. Addon1=", m_state.addon1_open,
              " Addon2=", m_state.addon2_open);
}
