#define FILE_NAME MQLInfoString(MQL_PROGRAM_NAME)+".bin"

#include <trade/trade.mqh>
#include <trade/positioninfo.mqh>

// =====================================
// Constants
// =====================================

#define SNAP_MAGIC 0xC0FFEE01   // frame marker, detect partial/garbage reads
#define COPY_MAGIC 770077       // expert magic, slave owns only these positions
#define MAX_RECORDS 1000        // sanity bound on record count
#define STALE_SEC   15          // master heartbeat timeout; older => freeze

enum ENUM_MODE
{
   MODE_MASTER,
   MODE_SLAVE
};

enum LotMode
{
   AUTO_RISK,
   MANUAL_LOT
};

enum RiskMode
{
   LIGHT,
   MEDIUM,
   HIGH
};

// =====================================
// Inputs
// =====================================

input ENUM_MODE Mode = MODE_SLAVE;

// Lot instellingen
input LotMode  LotSetting   = AUTO_RISK;
input RiskMode RiskSetting  = MEDIUM;
input double   ManualLotSize = 0.10;

CTrade trade;

// =====================================
// Snapshot model
// =====================================

struct MasterPos
{
   long   ticket;
   string sym;
   double vol;
   int    type;
   double priceOpen;
   double sl;
   double tp;
};

long g_lastSeq = -1;   // last reconciled seq, used to debounce

// =====================================
// Lot berekening
// =====================================

double CalculateLotSize(const string symbol)
{
   double lotSize;

   // =====================================
   // MANUAL LOT MODE
   // =====================================

   if(LotSetting == MANUAL_LOT)
   {
      lotSize = ManualLotSize;
   }
   else
   {
      // =====================================
      // AUTO RISK MODE
      // =====================================

      double balance = AccountInfoDouble(ACCOUNT_BALANCE);

      double lotPer1000;

      switch(RiskSetting)
      {
         case LIGHT:
            lotPer1000 = 0.01;
            break;

         case MEDIUM:
            lotPer1000 = 0.04;
            break;

         case HIGH:
            lotPer1000 = 0.10;
            break;

         default:
            lotPer1000 = 0.04;
            break;
      }

      // Lotsize berekenen
      lotSize = (balance / 1000.0) * lotPer1000;
   }

   // =====================================
   // Broker instellingen (van het gekopieerde symbool, niet de chart)
   // =====================================

   double minLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);

   if(lotStep <= 0.0)
      lotStep = 0.01;

   // Afronden op broker lotstep
   lotSize = MathRound(lotSize / lotStep) * lotStep;

   // Binnen broker limieten houden
   lotSize = MathMax(lotSize, minLot);
   lotSize = MathMin(lotSize, maxLot);

   return NormalizeDouble(lotSize, 2);
}

// =====================================
// Init
// =====================================

int OnInit()
{
   trade.SetExpertMagicNumber(COPY_MAGIC);   // slave tags + filters by this
   EventSetMillisecondTimer(500);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   EventKillTimer();
}

// =====================================
// MASTER: framed, atomic snapshot publish
// =====================================

void PublishSnapshot()
{
   string tmp = FILE_NAME + ".tmp";

   int f = FileOpen(tmp,
                    FILE_WRITE|FILE_BIN|FILE_COMMON|FILE_SHARE_READ);

   if(f == INVALID_HANDLE)
      return;

   static long seq = 0;
   seq++;

   int n = PositionsTotal();

   // Header: magic | seq | timestamp | count
   FileWriteInteger(f, (int)SNAP_MAGIC);
   FileWriteLong   (f, seq);
   FileWriteLong   (f, (long)TimeCurrent());
   FileWriteInteger(f, n);

   CPositionInfo pos;

   for(int i = n - 1; i >= 0; i--)
   {
      if(!pos.SelectByIndex(i))
         continue;

      FileWriteLong(f, (long)pos.Ticket());

      int length = StringLen(pos.Symbol());
      FileWriteInteger(f, length);
      FileWriteString(f, pos.Symbol());

      FileWriteDouble (f, pos.Volume());
      FileWriteInteger(f, pos.PositionType());
      FileWriteDouble (f, pos.PriceOpen());
      FileWriteDouble (f, pos.StopLoss());
      FileWriteDouble (f, pos.TakeProfit());
   }

   FileClose(f);

   // Atomic swap: reader sees old OR new file, never half-written.
   FileMove(tmp, FILE_COMMON, FILE_NAME, FILE_COMMON|FILE_REWRITE);
}

// =====================================
// SLAVE: validated snapshot read
// Returns false on missing/partial/garbage => caller does NOTHING.
// =====================================

bool ReadSnapshot(MasterPos &out[], long &seq, long &ts)
{
   int f = FileOpen(FILE_NAME,
                    FILE_READ|FILE_BIN|FILE_COMMON|FILE_SHARE_READ|FILE_SHARE_WRITE);

   if(f == INVALID_HANDLE)
      return false;

   int magic = FileReadInteger(f);
   if(magic != (int)SNAP_MAGIC)   // partial/garbage frame
   {
      FileClose(f);
      return false;
   }

   seq   = FileReadLong(f);
   ts    = FileReadLong(f);
   int n = FileReadInteger(f);

   if(n < 0 || n > MAX_RECORDS)   // sanity
   {
      FileClose(f);
      return false;
   }

   ArrayResize(out, n);

   for(int i = 0; i < n; i++)
   {
      out[i].ticket = FileReadLong(f);

      int length = FileReadInteger(f);
      out[i].sym  = FileReadString(f, length);

      out[i].vol       = FileReadDouble(f);
      out[i].type      = FileReadInteger(f);
      out[i].priceOpen = FileReadDouble(f);
      out[i].sl        = FileReadDouble(f);
      out[i].tp        = FileReadDouble(f);
   }

   // Short read detection: should be exactly at EOF after n records.
   if(!FileIsEnding(f))
   {
      FileClose(f);
      return false;
   }

   FileClose(f);
   return true;
}

// =====================================
// SLAVE: reconcile own positions to snapshot
// =====================================

void Reconcile(MasterPos &snap[])
{
   int n = ArraySize(snap);

   // ---- Pass 1: ensure each master position exists on slave ----
   for(int s = 0; s < n; s++)
   {
      long   mTicket = snap[s].ticket;
      bool   found   = false;

      CPositionInfo pos;

      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         if(!pos.SelectByIndex(i))
            continue;

         if(pos.Magic() != COPY_MAGIC)        // only our own copies
            continue;

         if(StringToInteger(pos.Comment()) != mTicket)
            continue;

         found = true;

         // SL/TP sync
         if(pos.StopLoss() != snap[s].sl || pos.TakeProfit() != snap[s].tp)
            trade.PositionModify(pos.Ticket(), snap[s].sl, snap[s].tp);

         break;
      }

      if(found)
         continue;

      // Open new copy
      double lot = CalculateLotSize(snap[s].sym);

      if(snap[s].type == POSITION_TYPE_BUY)
         trade.Buy (lot, snap[s].sym, 0, snap[s].sl, snap[s].tp, IntegerToString(mTicket));
      else if(snap[s].type == POSITION_TYPE_SELL)
         trade.Sell(lot, snap[s].sym, 0, snap[s].sl, snap[s].tp, IntegerToString(mTicket));
   }

   // ---- Pass 2: close own copies whose master is gone ----
   // Only runs on a VALID snapshot (caller guaranteed). Safe to close.
   CPositionInfo pos;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!pos.SelectByIndex(i))
         continue;

      if(pos.Magic() != COPY_MAGIC)           // never touch foreign trades
         continue;

      long cTicket = StringToInteger(pos.Comment());

      bool stillInMaster = false;
      for(int s = 0; s < n; s++)
      {
         if(snap[s].ticket == cTicket)
         {
            stillInMaster = true;
            break;
         }
      }

      if(!stillInMaster)
         trade.PositionClose(pos.Ticket());
   }
}

// =====================================
// Timer
// =====================================

void OnTimer()
{
   if(Mode == MODE_MASTER)
   {
      PublishSnapshot();
      return;
   }

   // MODE_SLAVE
   MasterPos snap[];
   long seq, ts;

   if(!ReadSnapshot(snap, seq, ts))
      return;                                  // bad/partial read => do nothing

   // Heartbeat: stale master => freeze. Do NOT close copies on staleness.
   if((long)TimeCurrent() - ts > STALE_SEC)
      return;

   // Debounce: only act when master state changed.
   if(seq == g_lastSeq)
      return;

   Reconcile(snap);
   g_lastSeq = seq;
}
