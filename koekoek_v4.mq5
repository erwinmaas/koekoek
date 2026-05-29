#define FILE_NAME MQLInfoString(MQL_PROGRAM_NAME)+".bin"

#include <trade/trade.mqh>
#include <trade/positioninfo.mqh>

// =====================================
// Constants
// =====================================

#define SNAP_MAGIC   0xC0FFEE01  // binary frame marker (file transport)
#define COPY_MAGIC   770077      // expert magic, slave owns only these positions
#define MAX_RECORDS  1000        // sanity bound on record count
#define STALE_SEC    15          // heartbeat timeout; older => slave freezes
#define RECONNECT_SEC 5          // min seconds between relay reconnect attempts
#define MAX_LINE     65536       // max relay frame length (anti-runaway buffer)
#define FRAME_TAG    "SNAP"      // relay text-frame prefix

enum ENUM_MODE
{
   MODE_MASTER,
   MODE_SLAVE
};

enum TransportMode
{
   LOCAL_FILE,   // shared common file, same machine (default, unchanged behavior)
   RELAY         // TCP relay server, remote master/slave on different machines
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

input ENUM_MODE     Mode      = MODE_SLAVE;
input TransportMode Transport = LOCAL_FILE;

// Relay instellingen (alleen gebruikt als Transport == RELAY)
// LET OP: voeg RelayHost toe aan Tools > Options > Expert Advisors >
//         "Allow WebRequest/connections to listed URL" lijst, anders
//         weigert de terminal de socketverbinding.
input string RelayHost   = "127.0.0.1";
input int    RelayPort   = 9000;
input bool   RelayUseTLS = false;          // true => server met --tls draaien
input string RelayToken  = "";             // gedeeld geheim, moet matchen met server

// Lot instellingen
input LotMode  LotSetting    = AUTO_RISK;
input RiskMode RiskSetting   = MEDIUM;
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

// ---- Relay state ----
int      g_sock          = INVALID_HANDLE;
bool     g_connected     = false;
string   g_recvBuffer    = "";
datetime g_lastConnectTry = 0;
datetime g_lastRecvTime   = 0;   // slave: local time of last valid frame (staleness)

// =====================================
// Lot berekening
// =====================================

double CalculateLotSize(const string symbol)
{
   double lotSize;

   if(LotSetting == MANUAL_LOT)
   {
      lotSize = ManualLotSize;
   }
   else
   {
      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      double lotPer1000;

      switch(RiskSetting)
      {
         case LIGHT:  lotPer1000 = 0.01; break;
         case MEDIUM: lotPer1000 = 0.04; break;
         case HIGH:   lotPer1000 = 0.10; break;
         default:     lotPer1000 = 0.04; break;
      }

      lotSize = (balance / 1000.0) * lotPer1000;
   }

   // Broker limieten van het GEKOPIEERDE symbool, niet de chart
   double minLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);

   if(lotStep <= 0.0)
      lotStep = 0.01;

   lotSize = MathRound(lotSize / lotStep) * lotStep;
   lotSize = MathMax(lotSize, minLot);
   lotSize = MathMin(lotSize, maxLot);

   return NormalizeDouble(lotSize, 2);
}

// =====================================
// Init / Deinit
// =====================================

int OnInit()
{
   trade.SetExpertMagicNumber(COPY_MAGIC);
   EventSetMillisecondTimer(500);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   RelayDisconnect();
}

// =====================================================================
// TRANSPORT: LOCAL FILE (binary, atomic) — unchanged from v3
// =====================================================================

void PublishSnapshotFile()
{
   string tmp = FILE_NAME + ".tmp";

   int f = FileOpen(tmp, FILE_WRITE|FILE_BIN|FILE_COMMON|FILE_SHARE_READ);
   if(f == INVALID_HANDLE)
      return;

   static long seq = 0;
   seq++;

   int n = PositionsTotal();

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
   FileMove(tmp, FILE_COMMON, FILE_NAME, FILE_COMMON|FILE_REWRITE);
}

// Returns false on missing/partial/garbage => caller does NOTHING.
bool ReadSnapshotFile(MasterPos &out[], long &seq, long &ts)
{
   int f = FileOpen(FILE_NAME, FILE_READ|FILE_BIN|FILE_COMMON|FILE_SHARE_READ|FILE_SHARE_WRITE);
   if(f == INVALID_HANDLE)
      return false;

   int magic = FileReadInteger(f);
   if(magic != (int)SNAP_MAGIC)
   {
      FileClose(f);
      return false;
   }

   seq   = FileReadLong(f);
   ts    = FileReadLong(f);
   int n = FileReadInteger(f);

   if(n < 0 || n > MAX_RECORDS)
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

   if(!FileIsEnding(f))   // short read => reject
   {
      FileClose(f);
      return false;
   }

   FileClose(f);
   return true;
}

// =====================================================================
// TRANSPORT: RELAY (TCP, text frames)
// Frame: SNAP|seq|ts|count|t;sym;vol;type;open;sl;tp|...   (newline-terminated)
// =====================================================================

bool RelaySendRaw(const string s)
{
   uchar buf[];
   int total = StringToCharArray(s, buf, 0, WHOLE_ARRAY, CP_UTF8);
   int len   = total - 1;            // strip trailing null terminator
   if(len < 0)
      return false;

   int sent = RelayUseTLS ? SocketTlsSend(g_sock, buf, len)
                          : SocketSend   (g_sock, buf, len);
   return (sent == len);
}

void RelayDisconnect()
{
   if(g_sock != INVALID_HANDLE)
      SocketClose(g_sock);
   g_sock       = INVALID_HANDLE;
   g_connected  = false;
   g_recvBuffer = "";
}

// Connect + handshake. Throttled. Returns true when connected & handshaken.
bool RelayEnsureConnected()
{
   if(g_connected && SocketIsConnected(g_sock))
      return true;

   // connection dropped => clean up before retry
   if(g_sock != INVALID_HANDLE)
      RelayDisconnect();

   if(TimeCurrent() - g_lastConnectTry < RECONNECT_SEC)
      return false;
   g_lastConnectTry = TimeCurrent();

   g_sock = SocketCreate();
   if(g_sock == INVALID_HANDLE)
   {
      Print("Relay: SocketCreate failed, err=", GetLastError());
      return false;
   }

   if(!SocketConnect(g_sock, RelayHost, RelayPort, 5000))
   {
      Print("Relay: connect to ", RelayHost, ":", RelayPort, " failed, err=", GetLastError());
      RelayDisconnect();
      return false;
   }

   if(RelayUseTLS)
   {
      if(!SocketTlsHandshake(g_sock, RelayHost))
      {
         Print("Relay: TLS handshake failed, err=", GetLastError());
         RelayDisconnect();
         return false;
      }
   }

   // Handshake line: "ROLE TOKEN\n"
   string role = (Mode == MODE_MASTER) ? "MASTER" : "SLAVE";
   if(!RelaySendRaw(role + " " + RelayToken + "\n"))
   {
      Print("Relay: handshake send failed");
      RelayDisconnect();
      return false;
   }

   g_connected   = true;
   g_recvBuffer  = "";
   g_lastRecvTime = TimeCurrent();   // grace period before first frame
   Print("Relay: connected as ", role, " to ", RelayHost, ":", RelayPort);
   return true;
}

// Pull all available bytes into g_recvBuffer.
void RelayPollRecv()
{
   uchar buf[];

   if(RelayUseTLS)
   {
      uint avail;
      while((avail = SocketTlsReadAvailable(g_sock)) > 0)
      {
         ArrayResize(buf, avail);
         int r = SocketTlsRead(g_sock, buf, avail);
         if(r <= 0)
            break;
         g_recvBuffer += CharArrayToString(buf, 0, r, CP_UTF8);
         if(StringLen(g_recvBuffer) > MAX_LINE * 4)   // runaway guard
         {
            g_recvBuffer = "";
            break;
         }
      }
   }
   else
   {
      uint avail;
      while((avail = SocketIsReadable(g_sock)) > 0)
      {
         ArrayResize(buf, avail);
         int r = SocketRead(g_sock, buf, avail, 10);
         if(r <= 0)
            break;
         g_recvBuffer += CharArrayToString(buf, 0, r, CP_UTF8);
         if(StringLen(g_recvBuffer) > MAX_LINE * 4)
         {
            g_recvBuffer = "";
            break;
         }
      }
   }
}

// Parse one text frame into snapshot. Strict: record count must match.
bool ParseFrame(const string line, MasterPos &out[], long &seq, long &ts)
{
   string parts[];
   int k = StringSplit(line, '|', parts);
   if(k < 4)
      return false;
   if(parts[0] != FRAME_TAG)
      return false;

   seq        = StringToInteger(parts[1]);
   ts         = StringToInteger(parts[2]);
   int count  = (int)StringToInteger(parts[3]);
   int recs   = k - 4;

   if(count < 0 || count > MAX_RECORDS)
      return false;
   if(recs != count)              // integrity: header count vs actual records
      return false;

   ArrayResize(out, count);
   for(int i = 0; i < count; i++)
   {
      string f[];
      int m = StringSplit(parts[4 + i], ';', f);
      if(m < 7)
         return false;

      out[i].ticket    = StringToInteger(f[0]);
      out[i].sym       = f[1];
      out[i].vol       = StringToDouble(f[2]);
      out[i].type      = (int)StringToInteger(f[3]);
      out[i].priceOpen = StringToDouble(f[4]);
      out[i].sl        = StringToDouble(f[5]);
      out[i].tp        = StringToDouble(f[6]);
   }
   return true;
}

// MASTER: build + send current state over relay.
void PublishSnapshotRelay()
{
   if(!RelayEnsureConnected())
      return;

   static long seq = 0;
   seq++;

   int n = PositionsTotal();

   // Build records first so header count matches exactly.
   string records = "";
   int written = 0;
   CPositionInfo pos;
   for(int i = n - 1; i >= 0; i--)
   {
      if(!pos.SelectByIndex(i))
         continue;

      records += "|" + IntegerToString(pos.Ticket()) + ";"
                     + pos.Symbol() + ";"
                     + DoubleToString(pos.Volume(), 2) + ";"
                     + IntegerToString(pos.PositionType()) + ";"
                     + DoubleToString(pos.PriceOpen(), 8) + ";"
                     + DoubleToString(pos.StopLoss(), 8) + ";"
                     + DoubleToString(pos.TakeProfit(), 8);
      written++;
   }

   string frame = FRAME_TAG + "|" + IntegerToString(seq) + "|"
                            + IntegerToString((long)TimeCurrent()) + "|"
                            + IntegerToString(written) + records + "\n";

   if(!RelaySendRaw(frame))
   {
      Print("Relay: send failed, dropping connection for retry");
      RelayDisconnect();
   }
}

// SLAVE: poll relay, parse the NEWEST complete frame received this tick.
// Returns true only when a valid new frame was parsed.
bool ReadSnapshotRelay(MasterPos &out[], long &seq, long &ts)
{
   if(!RelayEnsureConnected())
      return false;

   RelayPollRecv();

   // Extract complete newline-terminated lines; keep trailing partial.
   bool   got = false;
   string lastLine = "";

   int nl;
   while((nl = StringFind(g_recvBuffer, "\n")) >= 0)
   {
      lastLine     = StringSubstr(g_recvBuffer, 0, nl);
      g_recvBuffer = StringSubstr(g_recvBuffer, nl + 1);
      got = true;
   }

   if(!got)
      return false;   // no complete frame this tick

   // Only act on the most recent frame (older ones superseded).
   if(!ParseFrame(lastLine, out, seq, ts))
      return false;

   g_lastRecvTime = TimeCurrent();   // local receipt time => staleness clock
   return true;
}

// =====================================
// SLAVE: reconcile own positions to snapshot (transport-agnostic)
// =====================================

void Reconcile(MasterPos &snap[])
{
   int n = ArraySize(snap);

   // ---- Pass 1: ensure each master position exists on slave ----
   for(int s = 0; s < n; s++)
   {
      long mTicket = snap[s].ticket;
      bool found   = false;

      CPositionInfo pos;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         if(!pos.SelectByIndex(i))
            continue;
         if(pos.Magic() != COPY_MAGIC)
            continue;
         if(StringToInteger(pos.Comment()) != mTicket)
            continue;

         found = true;
         if(pos.StopLoss() != snap[s].sl || pos.TakeProfit() != snap[s].tp)
            trade.PositionModify(pos.Ticket(), snap[s].sl, snap[s].tp);
         break;
      }

      if(found)
         continue;

      double lot = CalculateLotSize(snap[s].sym);
      if(snap[s].type == POSITION_TYPE_BUY)
         trade.Buy (lot, snap[s].sym, 0, snap[s].sl, snap[s].tp, IntegerToString(mTicket));
      else if(snap[s].type == POSITION_TYPE_SELL)
         trade.Sell(lot, snap[s].sym, 0, snap[s].sl, snap[s].tp, IntegerToString(mTicket));
   }

   // ---- Pass 2: close own copies whose master is gone ----
   CPositionInfo pos;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!pos.SelectByIndex(i))
         continue;
      if(pos.Magic() != COPY_MAGIC)
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
   // ---------------- MASTER ----------------
   if(Mode == MODE_MASTER)
   {
      if(Transport == LOCAL_FILE)
         PublishSnapshotFile();
      else
         PublishSnapshotRelay();
      return;
   }

   // ---------------- SLAVE ----------------
   MasterPos snap[];
   long seq = 0, ts = 0;
   bool fresh = false;

   if(Transport == LOCAL_FILE)
   {
      if(!ReadSnapshotFile(snap, seq, ts))
         return;                              // bad/partial read => do nothing
      // file: master ts is same-machine clock => trustworthy
      if((long)TimeCurrent() - ts > STALE_SEC)
         return;                              // stale master => freeze
      if(seq == g_lastSeq)
         return;                              // debounce
      fresh = true;
   }
   else // RELAY
   {
      // Staleness uses LOCAL receipt time (cross-broker clocks may differ).
      bool newFrame = ReadSnapshotRelay(snap, seq, ts);

      if(TimeCurrent() - g_lastRecvTime > STALE_SEC)
         return;                              // no frames lately => freeze
      if(!newFrame)
         return;                              // nothing new this tick
      fresh = true;
   }

   if(!fresh)
      return;

   Reconcile(snap);
   g_lastSeq = seq;
}
