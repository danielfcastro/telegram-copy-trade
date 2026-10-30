//+------------------------------------------------------------------+
//|                                          TelegramSignalCopier.mq5|
//|                          Telegram signal copier for MetaTrader 5 |
//+------------------------------------------------------------------+
#property copyright "telegram-copy-trade"
#property version   "1.00"
#property strict
#property description "Signal source: JSON files from bridge/telegram_to_mt5.py,"
#property description "written into MQL5\\Files\\tg_signals (see below)."
#property description "Telegram login and groups are handled on the Python side"
#property description "only; the EA just reads that folder every InpPollSec seconds."
#property description "Read: PENDING at zone edge - BUY STOP upper / SELL LIMIT lower"
#property description "market if already at/past. TP1 close -> breakeven when"
#property description "conservative; TP2 close -> farthest order trails (InpTrailPts)"
#property description "Replies 'Moving SL to X' / 'Closing the signal' are handled."

#include <Trade\Trade.mqh>

//--- ======================= INPUTS =======================
input int    InpPollSec   = 15;   // Interval between scans of the bridge folder for new signal JSON files (seconds)
input long   InpMagic     = 20261019; // Magic number identifying our orders
input double InpLotGold   = 0.01; // Lot per order: gold (XAU/XAG/GOLD)
input double InpLotForex  = 0.2;  // Lot per order: currencies (forex)
input double InpLotETH    = 0.3;  // Lot per order: ETH (ETHUSD/XETH...)
input double InpLotBTC    = 0.03; // Lot per order: BTC (BTCUSD/XBT)
input int    InpMaxAgeMin = 120;  // Auto-delete untriggered PENDING orders after (minutes)
input int    InpMaxOpen   = 15;   // Max simultaneous open positions (3 per signal)
input double InpZoneTolPct= 0.0;  // Widen zone: moves the pending trigger edge earlier by % of its width
input int    InpDevPoints = 30;   // Deviation (points), only used for market-order fallbacks
input int    InpTrailPts  = -1;   // Trailing after middle TP closes: -1=auto(signal risk dist), 0=off, >0=pts
input bool   InpDebug     = true; // Verbose journal logging
input string InpStateFile = "tg_copier_state.txt"; // Stores last processed message id
input bool   InpDryRun    = false; // Dry run: never send orders, only log what WOULD be opened
input double InpRiskPct   = 0.0;   // Risk sizing: % of Balance at risk per signal (0 = use fixed lots below)
input string InpSignalsFolder = "tg_signals"; // Subfolder of MQL5\Files where the bridge (telegram_to_mt5.py) writes the signal JSONs
input bool   InpConservativeMode = true; // true: when the TP1 order closes with profit, remaining SLs move to breakeven; false: keep the original SLs
input int    InpCloseMaPeriod = 20;     // "Closing the signal" with negative P/L: short SLs to the SMA(period) of the chart timeframe; 0 = keep
input string InpSymbolMask  = "";       // Broker symbol mask: %s=pair as typed, %U=UPPER, %L=lower, %%=literal % ("%s!" -> XAUUSD!, "%L" -> xauusd). "" = auto-detect (old behavior)

//--- ======================= GLOBALS =======================
CTrade trade;
long     g_lastMsgId = 0;
datetime g_nextPoll  = 0;

struct Sig
  {
   long     msgId;
   datetime created;
   string   base;      // symbol as written in the message (BTCUSD)
   string   symbol;    // resolved broker symbol
   int      side;      // +1 = BUY, -1 = SELL
   double   eLow, eHigh;   // entry zone (0 = no zone -> open immediately)
   double   tp[3];     // take profit levels (0 = not defined)
   double   sl;        // stop loss
   double   lot;       // lot per order
   ulong    ticket[3]; // position tickets for TP1..TP3 (0 until the pending triggers)
   ulong    oticket[3];// pending-order tickets for TP1..TP3 (0 = market order / not placed)
   bool     trail[3];  // trailing-stop armed on this order (after the middle TP closed)
   double   trailv[3]; // last trailing SL applied (ratchet value)
   double   trailDist; // trailing distance in price units (0 = unused)
   bool     alive[3];  // position still open
   bool     done[3];   // position closed with profit (TP reached)
  };

Sig active[];    // signals with pending orders and/or open positions on the broker

//+------------------------------------------------------------------+
//| Logging                                                          |
//+------------------------------------------------------------------+
void LogMsg(string msg)
{
   if(InpDebug)
      Print("[TG-COPIER] ",msg);
}

//+------------------------------------------------------------------+
//| Small character helpers                                          |
//+------------------------------------------------------------------+
bool IsAlphaCh(ushort c)
{
   return (c>='A' && c<='Z') || (c>='a' && c<='z');
}
bool IsDigitCh(ushort c)
{
   return (c>='0' && c<='9');
}
string ToUpperAscii(string s)
{
   string out="";
   int L=StringLen(s);
   for(int i=0;i<L;i++)
   {
      ushort c=StringGetCharacter(s,i);
      if(c>='a' && c<='z') c=(ushort)(c-32);
      out+=ShortToString((ushort)(c & 0xFF));
   }
   return out;
}
int HexVal(ushort c)
{
   if(c>='0' && c<='9') return c-'0';
   if(c>='a' && c<='f') return c-'a'+10;
   if(c>='A' && c<='F') return c-'A'+10;
   return -1;
}
string Utf8Bytes(int cp)
{
   if(cp<0x80)   return ShortToString((ushort)cp);
   if(cp<0x800)
      return ShortToString((ushort)(0xC0|(cp>>6)))
           +ShortToString((ushort)(0x80|(cp&0x3F)));
   if(cp<0x10000)
      return ShortToString((ushort)(0xE0|(cp>>12)))
           +ShortToString((ushort)(0x80|((cp>>6)&0x3F)))
           +ShortToString((ushort)(0x80|(cp&0x3F)));
   return ShortToString((ushort)(0xF0|(cp>>18)))
        +ShortToString((ushort)(0x80|((cp>>12)&0x3F)))
        +ShortToString((ushort)(0x80|((cp>>6)&0x3F)))
        +ShortToString((ushort)(0x80|(cp&0x3F)));
}

//+------------------------------------------------------------------+
//| JSON: unescape a string value (handles \n \" \\ \uXXXX)          |
//+------------------------------------------------------------------+
string UnescapeJson(string raw)
{
   string out="";
   int L=StringLen(raw);
   for(int i=0;i<L;i++)
   {
      ushort c=StringGetCharacter(raw,i);
      if(c=='\\' && i+1<L)
      {
         ushort n=StringGetCharacter(raw,i+1);
         if(n=='n'){ out+="\n"; i++; continue; }
         if(n=='r'){ out+="\r"; i++; continue; }
         if(n=='t'){ out+="\t"; i++; continue; }
         if(n=='"'){ out+="\""; i++; continue; }
         if(n=='\\'){ out+="\\"; i++; continue; }
         if(n=='/'){ out+="/"; i++; continue; }
         if(n=='u' && i+5<L)
         {
            int cp=0; bool bad=false;
            for(int k=0;k<4;k++)
            {
               int h=HexVal(StringGetCharacter(raw,i+2+k));
               if(h<0){ bad=true; break; }
               cp=cp*16+h;
            }
            if(!bad){ out+=Utf8Bytes(cp); i+=5; continue; }
         }
         out+=ShortToString((ushort)n); i++; continue;
      }
      out+=ShortToString((ushort)(c & 0xFF));
   }
   return out;
}

//+------------------------------------------------------------------+
//| JSON: extract all "text" values and their preceding message_id   |
//+------------------------------------------------------------------+
void ExtractUpdates(string &json, long &ids[], string &texts[], long &replyIds[], string &replyTexts[])
{
   ArrayResize(ids,0); ArrayResize(texts,0); ArrayResize(replyIds,0); ArrayResize(replyTexts,0);
   int L=StringLen(json);
   int p=0;
   while(true)
   {
      int tpos=StringFind(json,"\"text\":",p);
      if(tpos<0) break;
      int q=tpos+7;
      while(q<L && (StringGetCharacter(json,q)==' '||StringGetCharacter(json,q)=='\r'||StringGetCharacter(json,q)=='\n')) q++;
      if(q>=L || StringGetCharacter(json,q)!='"'){ p=q; continue; }
      q++;
      string raw="";
      bool closed=false;
      while(q<L)
      {
         ushort c=StringGetCharacter(json,q);
         if(c=='\\')
         {
            raw+=ShortToString((ushort)c); q++;
            if(q<L){ raw+=ShortToString((ushort)(StringGetCharacter(json,q)&0xFF)); q++; }
            continue;
         }
         if(c=='"'){ closed=true; break; }
         raw+=ShortToString((ushort)(c&0xFF)); q++;
      }
      if(!closed){ p=q; continue; }
      // last "message_id": before this text
      string head=StringSubstr(json,0,tpos);
      long id=0;
      int midx=StringFind(head,"\"message_id\":");
      while(midx>=0)
      {
         int d=midx+13;   // length of "message_id":
         while(d<L && StringGetCharacter(json,d)==' ') d++;
         string num="";
         while(d<L && IsDigitCh(StringGetCharacter(json,d))){ num+=ShortToString((ushort)StringGetCharacter(json,d)); d++; }
         id=StringToInteger(num);
         midx=StringFind(head,"\"message_id\":",midx+1);
      }
      // "reply_to": / "reply_to_text": follow this record's text
      // (bridge files written before the thread fix simply lack them -> 0,"")
      long rtid=0; string rttext="";
      int nt=StringFind(json,"\"text\":",q);
      int rp=StringFind(json,"\"reply_to\":",q);
      if(rp>=0 && (nt<0 || rp<nt))
      {
         int d=rp+11;   // length of "reply_to":
         while(d<L && StringGetCharacter(json,d)==' ') d++;
         string num="";
         if(d<L && StringGetCharacter(json,d)=='-'){ num="-"; d++; }
         while(d<L && IsDigitCh(StringGetCharacter(json,d))){ num+=ShortToString((ushort)StringGetCharacter(json,d)); d++; }
         rtid=StringToInteger(num);
         int rtp=StringFind(json,"\"reply_to_text\":",q);
         if(rtp>=0 && (nt<0 || rtp<nt))
         {
            int e=rtp+16;   // length of "reply_to_text":
            while(e<L && StringGetCharacter(json,e)==' ') e++;
            if(e<L && StringGetCharacter(json,e)=='"')
            {
               e++;
               string raw2="";
               bool closed2=false;
               while(e<L)
               {
                  ushort c2=StringGetCharacter(json,e);
                  if(c2=='\\')
                  {
                     raw2+=ShortToString((ushort)c2); e++;
                     if(e<L){ raw2+=ShortToString((ushort)(StringGetCharacter(json,e)&0xFF)); e++; }
                     continue;
                  }
                  if(c2=='"'){ closed2=true; break; }
                  raw2+=ShortToString((ushort)(c2&0xFF)); e++;
               }
               if(closed2) rttext=UnescapeJson(raw2);
            }
         }
      }
      int n=ArraySize(texts);
      ArrayResize(texts,n+1); texts[n]=UnescapeJson(raw);
      ArrayResize(ids,n+1);   ids[n]=id;
      ArrayResize(replyIds,n+1);   replyIds[n]=rtid;
      ArrayResize(replyTexts,n+1); replyTexts[n]=rttext;
      p=q+1;
   }
}

//+------------------------------------------------------------------+
//| Word search with non-letter boundaries                           |
//+------------------------------------------------------------------+
bool MatchWordAt(string &s, int p, string w)
{
   int L=StringLen(s), wl=StringLen(w);
   if(p+wl>L) return false;
   for(int i=0;i<wl;i++)
      if(StringGetCharacter(s,p+i)!=StringGetCharacter(w,i)) return false;
   bool lb=(p==0)||(!IsAlphaCh(StringGetCharacter(s,p-1)));
   int e=p+wl;
   bool rb=(e>=L)||(!IsAlphaCh(StringGetCharacter(s,e)));
   return lb&&rb;
}
int FindWord(string &s, string w)
{
   int L=StringLen(s), wl=StringLen(w);
   int p=0;
   while((p=StringFind(s,w,p))>=0)
   {
      bool lb=(p==0)||(!IsAlphaCh(StringGetCharacter(s,p-1)));
      int e=p+wl;
      bool rb=(e>=L)||(!IsAlphaCh(StringGetCharacter(s,e)));
      if(lb&&rb) return p;
      p=e;
   }
   return -1;
}
void FindSignalKeywords(string &u, int &positions[])
{
   ArrayResize(positions,0);
   int L=StringLen(u);
   int p=0;
   while(p<L)
   {
      if(MatchWordAt(u,p,"BUY"))
      { int n=ArraySize(positions); ArrayResize(positions,n+1); positions[n]=p; p+=3; continue; }
      if(MatchWordAt(u,p,"SELL"))
      { int n=ArraySize(positions); ArrayResize(positions,n+1); positions[n]=p; p+=4; continue; }
      p++;
   }
}

//+------------------------------------------------------------------+
//| Number extraction: skips at most maxSkip non-digit chars         |
//+------------------------------------------------------------------+
bool GetNum(string &s, int &pos, double &val, int maxSkip)
{
   int L=StringLen(s);
   int p=pos;
   int skipped=0;
   while(p<L)
   {
      ushort c=StringGetCharacter(s,p);
      if((c>='0'&&c<='9')||c=='.') break;
      p++; skipped++;
      if(skipped>maxSkip){ pos=p; return false; }
   }
   if(p>=L){ pos=p; return false; }
   int q=p;
   bool dot=false;
   while(q<L)
   {
      ushort c=StringGetCharacter(s,q);
      if(c>='0'&&c<='9'){ q++; continue; }
      if(c=='.'&&!dot){ dot=true; q++; continue; }
      break;
   }
   string num=StringSubstr(s,p,q-p);
   if(num=="."){ pos=q; return GetNum(s,q,val,maxSkip); }
   val=StringToDouble(num);
   pos=q;
   return true;
}

//+------------------------------------------------------------------+
//| Parse one signal chunk into a Sig struct                         |
//+------------------------------------------------------------------+
bool ParseSignal(string chunk, Sig &s)
{
   ZeroMemory(s);
   string u=ToUpperAscii(chunk);
   int L=StringLen(u);

   int pBuy=FindWord(u,"BUY");
   int pSell=FindWord(u,"SELL");
   int kw=-1, side=0;
   if(pBuy>=0 && (pSell<0 || pBuy<pSell)){ side=1;  kw=pBuy;  }
   else if(pSell>=0){ side=-1; kw=pSell; }
   else return false;
   s.side=side;

   //--- symbol: first alphabetic token after the keyword
   int q=kw+(side>0?3:4);
   while(q<L && !IsAlphaCh(StringGetCharacter(u,q))) q++;
   string sym="";
   while(q<L)
   {
      ushort c=StringGetCharacter(u,q);
      if((c>='A'&&c<='Z')||c=='/'){ sym+=ShortToString((ushort)c); q++; }
      else break;
   }
   string sym2="";
   for(int i2=0;i2<StringLen(sym);i2++)
   {
      ushort c=StringGetCharacter(sym,i2);
      if(c!='/') sym2+=ShortToString((ushort)c);
   }
   if(StringLen(sym2)<3) return false;
   if(StringLen(sym2)==3) sym2+="USD";   // BTC->BTCUSD, ETH->ETHUSD, XAU->XAUUSD
   s.base=sym2;

   //--- entry zone
   string entryKeys[4]= {"ENTRY","ENTRADA","ZONA","ZONE"};
   int ep=-1, elen=0;
   for(int k=0;k<4;k++)
   {
      int p=FindWord(u,entryKeys[k]);
      if(p>=0){ ep=p; elen=StringLen(entryKeys[k]); break; }
   }
   if(ep>=0)
   {
      int pos=ep+elen;
      double a=0,b=0;
      bool ok1=GetNum(u,pos,a,10);
      bool ok2=GetNum(u,pos,b,8);
      if(ok1)
      {
         if(ok2){ s.eLow=MathMin(a,b); s.eHigh=MathMax(a,b); }
         else   { s.eLow=a; s.eHigh=a; }
      }
   }

   //--- TP1..TP3
   for(int i=0;i<3;i++)
   {
      string key="TP"+IntegerToString(i+1);
      int kp=FindWord(u,key);
      if(kp<0) continue;
      int pos=kp+StringLen(key);
      double v=0;
      if(GetNum(u,pos,v,6)) s.tp[i]=v;
   }
   if(s.tp[0]<=0)   // plain "TP:" treated as TP1
   {
      int kp=FindWord(u,"TP");
      if(kp>=0)
      {
         int pos=kp+2;
         if(pos>=StringLen(u) || !IsDigitCh(StringGetCharacter(u,pos)))
         { double v=0; if(GetNum(u,pos,v,6)) s.tp[0]=v; }
      }
   }

   //--- SL / STOP / S/L
   string slKeys[3]= {"SL","STOP","S/L"};
   int sp=-1, slen=0;
   for(int k=0;k<3;k++)
   {
      int p=FindWord(u,slKeys[k]);
      if(p>=0){ sp=p; slen=StringLen(slKeys[k]); break; }
   }
   if(sp>=0)
   {
      int pos=sp+slen;
      double v=0;
      if(GetNum(u,pos,v,8)) s.sl=v;
   }

   //--- validation
   if(s.sl<=0) return false;
   if(s.tp[0]<=0) return false;
   if(s.side>0 && s.tp[0]<=s.sl) return false;   // levels look inverted
   if(s.side<0 && s.tp[0]>=s.sl) return false;
   if(s.eLow>0 && s.side>0 && s.sl>s.eLow)
      LogMsg("warning: BUY signal SL "+DoubleToString(s.sl,2)+" is above the entry zone");
   if(s.eLow>0 && s.side<0 && s.sl<s.eHigh)
      LogMsg("warning: SELL signal SL "+DoubleToString(s.sl,2)+" is below the entry zone");
   return true;
}

//+------------------------------------------------------------------+
//| Lot size by category (per order)                                 |
//+------------------------------------------------------------------+
double GetLot(string base)
{
   if(StringFind(base,"XAU")>=0 || StringFind(base,"XAG")>=0 || StringFind(base,"GOLD")>=0)
      return InpLotGold;
   if(StringFind(base,"BTC")>=0 || StringFind(base,"XBT")>=0)
      return InpLotBTC;
   if(StringFind(base,"ETH")>=0)
      return InpLotETH;
   return InpLotForex;
}

//+------------------------------------------------------------------+
//| Expand a symbol mask: %s=base as typed, %U=UPPER, %L=lower,     |
//| %%=literal %. ASCII folding only (no locale surprises).          |
//+------------------------------------------------------------------+
string ExpandMask(string pattern,string base)
{
    string up="", lo="";
    for(int i=0;i<StringLen(base);i++) {
        ushort c=StringGetCharacter(base,i);
        if(c>='a' && c<='z') {
            up+=ShortToString((ushort)(c-32));
            lo+=ShortToString(c);
        } else if(c>='A' && c<='Z') {
            up+=ShortToString(c);
            lo+=ShortToString((ushort)(c+32));
        } else {
            up+=ShortToString(c);
            lo+=ShortToString(c);
        }
    }
    string o="";
    int L=StringLen(pattern);
    for(int i=0;i<L;i++) {
        ushort c=StringGetCharacter(pattern,i);
        if(c=='%' && i+1<L) {
            ushort n=StringGetCharacter(pattern,i+1);
            if(n=='s') {
                o+=base;
                i++;
                continue;
            }
            if(n=='U') {
                o+=up;
                i++;
                continue;
            }
            if(n=='L') {
                o+=lo;
                i++;
                continue;
            }
            if(n=='%') {
                o+="%";
                i++;
                continue;
            }
        }
        o+=ShortToString(c);
    }
    return o;
}

//+------------------------------------------------------------------+
//| Resolve broker symbol. If InpSymbolMask is set the symbol is     |
//| built from the mask and verified on this broker (e.g. "%s!" for  |
//| XAUUSD!, "usd_%L"); if the mask misses, log and fall back to    |
//| auto-detect: exact name first, then any listed symbol whose name |
//| contains the base (handles suffixed names like BTCUSDm/XAUUSD!). |
//+------------------------------------------------------------------+
bool ResolveSymbol(string base, string &out)
{
    if(InpSymbolMask!="") {
        string cand=ExpandMask(InpSymbolMask,base);
        bool mc=false;
        if(SymbolExist(cand,mc)) {
            out=cand;
            return true;
        }
        LogMsg("warning: InpSymbolMask '"+InpSymbolMask+"' produced '"+cand+"' which is not on this broker - falling back to auto-detect");
    }
    bool custom=false;
    if(SymbolExist(base,custom)) {
        out=base;
        return true;
    }
    int n=SymbolsTotal(false);
    for(int i=0;i<n;i++) {
        string s=SymbolName(i,false);
        if(StringFind(s,base)>=0) {
            out=s;
            return true;
        }
    }
    return false;
}

//+------------------------------------------------------------------+
//| Normalize lot to symbol volume step/min                          |
//+------------------------------------------------------------------+
double NormalizeLot(string symbol, double lot)
{
   double step=SymbolInfoDouble(symbol,SYMBOL_VOLUME_STEP);
   double min =SymbolInfoDouble(symbol,SYMBOL_VOLUME_MIN);
   double max =SymbolInfoDouble(symbol,SYMBOL_VOLUME_MAX);
   if(step>0) lot=MathFloor(lot/step+1e-8)*step;
   if(lot<min) return 0.0;   // too small for this broker
   if(lot>max) lot=max;
   return lot;
}

//+------------------------------------------------------------------+
//| Risk-based lot: the WHOLE signal may lose at most InpRiskPct %   |
//| of Balance. The signal is split in one order per TP, all sharing |
//| the same SL and opened at the same price, so each order carries  |
//| 1/n of the risk: loss_i = |entry - SL| * lot * value-per-point. |
//| The TPs only decide the REWARD (entry -> TPi), not the risk, so  |
//| they do not change the lot; they are shown in the log.           |
//| Lot is always clamped to [0.01 .. 100].                          |
//+------------------------------------------------------------------+
double RiskLot(string symbol,int side,double sl,double eLow,double eHigh,int orders)
{
   if(orders<1) orders=1;
   double tickVal=SymbolInfoDouble(symbol,SYMBOL_TRADE_TICK_VALUE);
   double tickSz =SymbolInfoDouble(symbol,SYMBOL_TRADE_TICK_SIZE);
   double balance=AccountInfoDouble(ACCOUNT_BALANCE);
   if(tickVal<=0 || tickSz<=0 || balance<=0 || InpRiskPct<=0) return 0.0;
   // risk distance is measured from where the market orders will be created:
   // the current quote if inside the zone, otherwise the zone edge closest to price.
   double cur=(side>0)?iAskPrice(symbol,0):iBidPrice(symbol,0);
   double entry=cur;
   if(eLow>0){
      if(cur<eLow)  entry=eLow;
      if(cur>eHigh) entry=eHigh;
   }
   double dist=MathAbs(entry-sl);
   if(dist<=0) return 0.0;
   double riskTotal=balance*InpRiskPct/100.0;          // max loss for the signal
   double moneyPerLotUnit=(dist/tickSz)*tickVal;       // loss for lot=1 over dist
   double lot=riskTotal/(double)orders/moneyPerLotUnit; // per-order lot
   if(lot<0.01) lot=0.01;                              // hard floor
   if(lot>100)  lot=100;                               // hard cap
   double norm=NormalizeLot(symbol,lot);
   if(norm<=0)                                          // broker step rounded down
   {
      norm=SymbolInfoDouble(symbol,SYMBOL_VOLUME_MIN);
      if(norm<0.01) norm=0.01;
      if(norm>100) norm=100;
      norm=NormalizeLot(symbol,norm);
      if(norm<=0) return 0.0;
   }
   if(norm>100) norm=100;
   LogMsg("risk sizing: balance="+DoubleToString(balance,2)+" risk="+DoubleToString(riskTotal,2)+
          " ("+DoubleToString(InpRiskPct,2)+"%) slDist="+DoubleToString(dist,2)+
          " -> lot/order="+DoubleToString(norm,2)+" (raw "+DoubleToString(lot,8)+")");
   return norm;
}

//+------------------------------------------------------------------+
//| Count our open positions                                         |
//+------------------------------------------------------------------+
int CountOurPositions()
{
   int c=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong tk=PositionGetTicket(i);
      if(tk==0) continue;
      if(PositionGetInteger(POSITION_MAGIC)==InpMagic) c++;
   }
   return c;
}

bool PositionIsOpen(ulong ticket)
{
   for(int i=PositionsTotal()-1;i>=0;i--)
      if(PositionGetTicket(i)==ticket) return true;
   return false;
}

double PositionOpenPrice(ulong ticket)
{
   for(int i=PositionsTotal()-1;i>=0;i--)
      if(PositionGetTicket(i)==ticket)
         return PositionGetDouble(POSITION_PRICE_OPEN);
   return 0.0;
}

//+------------------------------------------------------------------+
//| Find the position ticket we just opened (matched by TP level)    |
//+------------------------------------------------------------------+
ulong FindTicket(string symbol, int side, double tp)
{
   double pt=SymbolInfoDouble(symbol,SYMBOL_POINT);
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong tk=PositionGetTicket(i);
      if(tk==0) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL)!=symbol) continue;
      bool buy=(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY);
      if(side>0 && !buy) continue;
      if(side<0 && buy) continue;
      if(MathAbs(PositionGetDouble(POSITION_TP)-tp)>pt*2.0) continue;
      return tk;
   }
   return 0;
}

//+------------------------------------------------------------------+
//| Current quotes (the p parameter is kept for call-site symmetry; |
//| we always take the live top-of-book price)                       |
//+------------------------------------------------------------------+
double iAskPrice(string s,int p){ return SymbolInfoDouble(s,SYMBOL_ASK); }
double iBidPrice(string s,int p){ return SymbolInfoDouble(s,SYMBOL_BID); }
int SymbolDigits(string s){ return (int)SymbolInfoInteger(s,SYMBOL_DIGITS); }

//+------------------------------------------------------------------+
//| Find our still-open PENDING order for a signal (matched by magic,|
//| symbol, side and TP level) - returns its order ticket or 0.      |
//+------------------------------------------------------------------+
ulong OurOpenOrderTicket(string sym,int side,double tp)
{
   double pt=SymbolInfoDouble(sym,SYMBOL_POINT);
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      ulong tk=OrderGetTicket(i);
      if(tk==0) continue;
      if(OrderGetInteger(ORDER_MAGIC)!=InpMagic) continue;
      if(OrderGetString(ORDER_SYMBOL)!=sym) continue;
      long ot=OrderGetInteger(ORDER_TYPE);
      bool isBuy=(ot==ORDER_TYPE_BUY_STOP || ot==ORDER_TYPE_BUY_LIMIT || ot==ORDER_TYPE_BUY);
      bool isSell=(ot==ORDER_TYPE_SELL_STOP || ot==ORDER_TYPE_SELL_LIMIT || ot==ORDER_TYPE_SELL);
      if(side>0 && !isBuy) continue;
      if(side<0 && !isSell) continue;
      if(MathAbs(OrderGetDouble(ORDER_TP)-tp)>pt*2.0) continue;
      return tk;
   }
   return 0;
}

int CountOurOpenOrders()
{
   int c=0;
   for(int i=0;i<OrdersTotal();i++)
      if(OrderGetInteger(ORDER_MAGIC)==InpMagic) c++;
   return c;
}

bool OurOpenSourceExists(string sym,int side)
{
   for(int i=0;i<PositionsTotal();i++)
   {
      ulong tk=PositionGetTicket(i);
      if(tk==0) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL)!=sym) continue;
      bool buy=((int)PositionGetInteger(POSITION_TYPE)==(int)POSITION_TYPE_BUY);
      if((side>0&&buy)||(side<0&&!buy)) return true;
   }
   for(int i=0;i<OrdersTotal();i++)
   {
      ulong tk=OrderGetTicket(i);
      if(tk==0) continue;
      if(OrderGetInteger(ORDER_MAGIC)!=InpMagic) continue;
      if(OrderGetString(ORDER_SYMBOL)!=sym) continue;
      long ot=OrderGetInteger(ORDER_TYPE);
      bool isBuy=(ot==ORDER_TYPE_BUY_STOP || ot==ORDER_TYPE_BUY_LIMIT || ot==ORDER_TYPE_BUY);
      if((side>0&&isBuy)||(side<0&&!isBuy)) return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| The in-memory zone state machine was REMOVED: waiting for the    |
//| entry zone is now done with REAL pending orders placed at the    |
//| zone edge the moment the signal JSON is read (BUY STOP at the   |
//| upper edge, SELL LIMIT at the lower edge) - see OpenSignal().    |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Place the signal's orders. WITH an entry zone the EA does NOT    |
//| wait in memory: the moment the JSON is read it sends real PENDING|
//| orders at the zone edge - BUY STOP at the UPPER edge if BUY,     |
//| SELL LIMIT at the LOWER edge if SELL (as requested) - one per    |
//| TP, all sharing the SL. The terminal triggers them itself.        |
//| If the current price is already at/past that edge the pending    |
//| would be invalid, so market orders are sent instead (late entry);|
//| signals without a zone also go straight to market orders.        |
//+------------------------------------------------------------------+
void OpenSignal(Sig &s)
{
   bool any=false;
   int dg=SymbolDigits(s.symbol);
   bool hasZone=(s.eLow>0 && s.eHigh>s.eLow);
   double w=(s.eHigh-s.eLow)*InpZoneTolPct/100.0;   // tolerance shifts the trigger edge earlier
   double level=0.0;
   bool canPend=false;
   if(hasZone)
   {
      level=(s.side>0) ? s.eHigh+w : s.eLow-w;
      // a pending price must also respect the broker's stops level: MT5
      // rejects a BuyStop/SellLimit whose price is closer to the current
      // quote than SYMBOL_TRADE_STOPS_LEVEL ("invalid price"). Keep the
      // pending only when the edge clears that band; otherwise market.
      double stp=SymbolInfoInteger(s.symbol,SYMBOL_TRADE_STOPS_LEVEL)*SymbolInfoDouble(s.symbol,SYMBOL_POINT);
      // both order types we actually place (BUY STOP for BUY, SELL LIMIT for
      // SELL) wait for the price to rise to the edge: both sit ABOVE the
      // market, so the terminal validates both with the same rule - order
      // price >= Ask + stops level. The old per-side test applied the
      // SELL STOP rule (Bid - stops level) to the SELL branch, which is
      // inverted: it kept a SellLimit that is always rejected [invalid
      // price] and fell back to market when the pending would have been
      // valid. Keep the pending only when the edge clears that band.
      canPend=(iAskPrice(s.symbol,0)+stp<level);
   }
   //+ log format (as requested): ORDER TYPE - SYMBOL - RISK% - LOT - TP - SL,
   //  plus WHY pending vs market was chosen (price inside/outside the zone)
   string orderType;
   if(canPend)      orderType=(s.side>0)?"PENDING BUY STOP ":"PENDING SELL LIMIT ";
   else             orderType=(s.side>0)?"MARKET BUY ":"MARKET SELL ";
   string riskTag;
   if(InpRiskPct>0) riskTag="RISK="+DoubleToString(InpRiskPct,2)+"% ";
   else             riskTag="RISK=off(fixed lots) ";
   string reason;
   if(canPend)      reason="  - price outside the zone: terminal will trigger it when price reaches "+DoubleToString(level,dg);
   else if(hasZone) reason="  - price at/inside zone or within broker stops-level band: market entry";
   else             reason="  - signal without entry zone: market entry";
   for(int i=0;i<3;i++)
   {
      s.ticket[i]=0; s.oticket[i]=0; s.alive[i]=false; s.done[i]=false; s.trail[i]=false; s.trailv[i]=0.0;
      if(s.tp[i]<=0) continue;
      string lineSpec=orderType+s.symbol+" "+riskTag+
            "LOT="+DoubleToString(s.lot,2)+"  TP"+IntegerToString(i+1)+"="+DoubleToString(s.tp[i],dg)+
            "  SL="+DoubleToString(s.sl,dg)+reason;
      if(InpDryRun)
      {
         LogMsg("[DRY-RUN] would place "+lineSpec+"  (no order sent)");
         continue;
      }
      trade.SetTypeFillingBySymbol(s.symbol);
      bool res=false;
      if(canPend)
         res=(s.side>0)
             ? trade.BuyStop (s.lot,level,s.symbol,s.sl,s.tp[i],ORDER_TIME_GTC,0,"TG SIG")
             : trade.SellLimit(s.lot,level,s.symbol,s.sl,s.tp[i],ORDER_TIME_GTC,0,"TG SIG");
      else
         res=(s.side>0)
             ? trade.Buy (s.lot,s.symbol,0.0,s.sl,s.tp[i],"TG SIG")
             : trade.Sell(s.lot,s.symbol,0.0,s.sl,s.tp[i],"TG SIG");
      if(!res)
      {
         LogMsg(lineSpec+"  - ORDER REJECTED by broker");
         continue;
      }
      if(canPend)
      {
         s.oticket[i]=trade.ResultOrder();   // pending order ticket (position ticket unknown yet)
         any=true;
         LogMsg(lineSpec);
         continue;
      }
      ulong tk=FindTicket(s.symbol,s.side,s.tp[i]);
      s.ticket[i]=tk;
      s.alive[i]=(tk!=0);
      any=true;
      LogMsg(lineSpec);
   }
   if(any)
   {
      int n=ArraySize(active);
      ArrayResize(active,n+1);
      active[n]=s;
   }
}

//+------------------------------------------------------------------+
//| Handle one parsed signal                                         |
//+------------------------------------------------------------------+
void HandleSignal(Sig &s)
{
   string sym="";
   if(!ResolveSymbol(s.base,sym))
   {
      LogMsg("cannot resolve symbol "+s.base+" on this broker - signal skipped");
      return;
   }
   s.symbol=sym;
   int nTp=0; for(int t=0;t<3;t++) if(s.tp[t]>0) nTp++;
   double lot=0.0;
   if(InpRiskPct>0)
      lot=RiskLot(sym,s.side,s.sl,s.eLow,s.eHigh,nTp);
   else
      lot=NormalizeLot(sym,GetLot(s.base));
   if(lot<=0)
   {
      LogMsg("lot for "+sym+" is below the minimum / risk not computable - signal skipped");
      return;
   }
   s.lot=lot;

   // duplicate: same symbol+side already pending or open, checked both in
   // tracking and directly against the broker (survives EA restarts)
   for(int i=0;i<ArraySize(active);i++)
      if(active[i].symbol==s.symbol && active[i].side==s.side){
         LogMsg("duplicate signal (pending or already open in tracking) - skipped"); return; }
   if(OurOpenSourceExists(s.symbol,s.side)){
      LogMsg("duplicate signal (our open pending order/position on the broker) - skipped"); return; }

   if(CountOurPositions()+CountOurOpenOrders()+nTp>InpMaxOpen){
      LogMsg("too many open orders/positions (max "+IntegerToString(InpMaxOpen)+") - signal skipped"); return; }

   // as requested: act the moment the JSON is read; waiting for the entry
   // zone is done with a real pending order at the zone edge (OpenSignal
   // decides pending vs. market from the current price)
   OpenSignal(s);
}

//+------------------------------------------------------------------+
//| Management replies from the channel ("Moving SL to X",           |
//| "Closing the signal"): located by named pair; if the message     |
//| names none, only acted on when exactly one signal is active.    |
//+------------------------------------------------------------------+
string BrokerBaseWord(string sym)   // "BTCUSD!" -> "BTCUSD"
{
   string b=sym;
   for(int k=StringLen(b)-1;k>=0;k--)
   {
      ushort c=StringGetCharacter(b,k);
      bool alnum=(c>='A'&&c<='Z')||(c>='0'&&c<='9');
      if(alnum) break;
      b=StringSubstr(b,0,k);
   }
   return b;
}
int FindManagementTarget(string &u)
{
   int hit=-1,hits=0;
   for(int i=ArraySize(active)-1;i>=0;i--)
   {
      string b=BrokerBaseWord(active[i].symbol);
      if(b!="" && FindWord(u,b)>=0){ hit=i; hits++; }
   }
   if(hits==1) return hit;
   if(hits==0 && ArraySize(active)==1) return 0;   // reply without pair: one active signal
   if(hits==0)
   { LogMsg("management message names no pair and "+IntegerToString(ArraySize(active))+" signals are active - skipped (ambiguous)"); return -1; }
   LogMsg("management message names several pairs - skipped");
   return -1;
}

//+------------------------------------------------------------------+
//| Resolve the target of a management reply by its Telegram thread   |
//| first: the replied-to message id matches the tracked signal      |
//| exactly; after an EA restart that link is gone from memory, but |
//| the replied-to text still identifies the signal (re-parse it, or |
//| match the pair it names). -1 = not resolvable (heuristic below). |
//+------------------------------------------------------------------+
int ResolveReplyTarget(long replyTo, string &replyText)
{
   if(replyTo<=0) return -1;
   string r=ToUpperAscii(replyText);
   if(r!="")
   {
      Sig s;
      if(ParseSignal(r,s))
      {
         string sym="";
         if(ResolveSymbol(s.base,sym))
            for(int i=ArraySize(active)-1;i>=0;i--)
               if(active[i].symbol==sym && active[i].side==s.side) return i;
      }
   }
   // msg ids repeat per chat, so the quoted text above has priority
   for(int i=ArraySize(active)-1;i>=0;i--)
      if(active[i].msgId==replyTo) return i;
   if(r!="")
      for(int i=ArraySize(active)-1;i>=0;i--)
      {
         string b=BrokerBaseWord(active[i].symbol);
         if(b!="" && FindWord(r,b)>=0) return i;
      }
   return -1;
}
bool IsCloseSignalMsg(string &u)
{
   return StringFind(u,"CLOSING THE SIGNAL")>=0 || StringFind(u,"CLOSE THE SIGNAL")>=0
       || StringFind(u,"SIGNAL CLOSED")>=0 || StringFind(u,"CLOSE SIGNAL")>=0;
}
bool IsSlMoveMsg(string &u)
{
   return StringFind(u,"MOVING SL")>=0 || StringFind(u,"MOVE SL")>=0
       || StringFind(u,"SL MOVED")>=0 || StringFind(u,"MOVING STOP LOSS")>=0
       || StringFind(u,"STOP LOSS MOVED")>=0;
}
double ExtractSlMoveValue(string &u)
{
   string ph[]={"MOVING SL TO","MOVE SL TO","MOVING STOP LOSS TO","STOP LOSS MOVED TO","SL MOVED TO","MOVING SL","SL MOVED"};
   for(int k=0;k<ArraySize(ph);k++)
   {
      int p=StringFind(u,ph[k]);
      if(p<0) continue;
      p+=StringLen(ph[k]);
      int L=StringLen(u);
      while(p<L){ ushort c=StringGetCharacter(u,p); if(c==' '||c==':'||c=='\t'||c=='\r'||c=='\n'){p++;continue;} break; }
      string num="";
      while(p<L)
      {
         ushort c=StringGetCharacter(u,p);
         bool dig=(c>='0'&&c<='9');
         if(!dig && c!='.') break;
         num+=ShortToString((ushort)c); p++;
      }
      double v=0.0, mult=1.0; bool seenDot=false;
      for(int c2=0;c2<StringLen(num);c2++)
      {
         ushort ch=StringGetCharacter(num,c2);
         if(ch=='.'){ seenDot=true; continue; }
         int dch=(int)ch-(int)'0';
         if(dch<0||dch>9) continue;
         if(!seenDot) v=v*10.0+(double)dch;
         else { mult/=10.0; v+=(double)dch*mult; }
      }
      if(v>0.0) return v;
   }
   return -1.0;
}
double PositionPnlOnTicket(ulong tk)
{
   for(int i=PositionsTotal()-1;i>=0;i--)
      if(PositionGetTicket(i)==tk) return PositionGetDouble(POSITION_PROFIT);
   return 0.0;
}
void ApplyMoveSlTo(int idx,double x)
{
   string sym=active[idx].symbol;
   int dg=SymbolDigits(sym);
   active[idx].sl=x;
   int touched=0;
   for(int j=0;j<3;j++)
   {
      if(active[idx].tp[j]<=0) continue;
      ulong tk=active[idx].ticket[j];
      if(tk!=0 && PositionIsOpen(tk))
      {
         if(trade.PositionModify(tk,x,active[idx].tp[j]))
         { touched++; LogMsg("MANUAL SL -> "+DoubleToString(x,dg)+" on position ticket "+IntegerToString((long)tk)+" ("+sym+" TP"+IntegerToString(j+1)+")"); }
         else LogMsg("MANUAL SL rejected on position ticket "+IntegerToString((long)tk));
         continue;
      }
      ulong ot=active[idx].oticket[j];
      if(ot!=0)
      {
         bool sel=false; double pr=0.0,tpx=0.0;
         for(int q2=OrdersTotal()-1;q2>=0;q2--)
         {
            ulong qk=OrderGetTicket(q2);
            if(qk!=ot) continue;
            pr=OrderGetDouble(ORDER_PRICE_CURRENT); tpx=OrderGetDouble(ORDER_TP); sel=true; break;
         }
         if(!sel) continue;
         // CTrade::OrderModify in THIS build: (ticket,price,sl,tp,ENUM_ORDER_TYPE_TIME,datetime,price stop)
         if(trade.OrderModify(ot,pr,x,tpx,ORDER_TIME_GTC,0,0.0))
         { touched++; LogMsg("MANUAL SL -> "+DoubleToString(x,dg)+" on pending ticket "+IntegerToString((long)ot)+" ("+sym+" TP"+IntegerToString(j+1)+")"); }
      }
   }
   if(touched==0) LogMsg("manual SL to "+DoubleToString(x,dg)+": no open position/pending left for "+sym);
}
void ApplyCloseSignal(int idx)
{
   string sym=active[idx].symbol;
   int dg=SymbolDigits(sym);
   double pnl=0.0; int opens=0;
   for(int j=0;j<3;j++)
   {
      if(active[idx].tp[j]<=0) continue;
      ulong tk=active[idx].ticket[j];
      if(tk!=0 && PositionIsOpen(tk)){ pnl+=PositionPnlOnTicket(tk); opens++; }
   }
   LogMsg("close requested for "+sym+": open P/L="+DoubleToString(pnl,2)+" ("+IntegerToString(opens)+" positions)");
   for(int j=0;j<3;j++)   // untriggered pendings are dropped in both branches
   {
      ulong ot=active[idx].oticket[j];
      if(ot!=0){ if(trade.OrderDelete(ot)) LogMsg("untriggered pending TP"+IntegerToString(j+1)+" deleted (close requested)"); active[idx].oticket[j]=0; }
   }
   if(pnl>0.0)
   {
      for(int j=0;j<3;j++)
      {
         ulong tk=active[idx].ticket[j];
         if(tk!=0 && PositionIsOpen(tk))
         {
            if(trade.PositionClose(tk))
            { active[idx].done[j]=true; active[idx].alive[j]=false;
              LogMsg("CLOSED position ticket "+IntegerToString((long)tk)+" (signal closed on request, P/L positive)"); }
            else LogMsg("PositionClose rejected for ticket "+IntegerToString((long)tk));
         }
      }
      return;
   }
   if(InpCloseMaPeriod<=0)
   { LogMsg("negative P/L and InpCloseMaPeriod=0 -> keeping current stops"); return; }
   double ma=0.0;
   for(int k=0;k<InpCloseMaPeriod;k++) ma+=iClose(sym,PERIOD_CURRENT,k);
   if(InpCloseMaPeriod>0) ma/=(double)InpCloseMaPeriod;
   if(ma<=0.0){ LogMsg("SMA("+IntegerToString(InpCloseMaPeriod)+") unavailable for "+sym+" - keeping stops"); return; }
   LogMsg("negative P/L: shorting stops to SMA("+IntegerToString(InpCloseMaPeriod)+") = "+DoubleToString(ma,dg)+", letting the stop decide");
   for(int j=0;j<3;j++)
   {
      ulong tk=active[idx].ticket[j];
      if(!(tk!=0 && PositionIsOpen(tk))) continue;
      double oldsl=0.0; bool ok=false;
      for(int q=PositionsTotal()-1;q>=0;q--)
         if(PositionGetTicket(q)==tk){ oldsl=PositionGetDouble(POSITION_SL); ok=true; break; }
      if(!ok) continue;
      double nt=(active[idx].side>0)?(ma>oldsl?ma:oldsl):(ma<oldsl?ma:oldsl);  // only tighten
      if(nt==oldsl) continue;
      if(trade.PositionModify(tk,nt,active[idx].tp[j]))
      { active[idx].sl=nt; LogMsg("SL shorted to "+DoubleToString(nt,dg)+" on ticket "+IntegerToString((long)tk)+" ("+sym+" TP"+IntegerToString(j+1)+")"); }
   }
}

//+------------------------------------------------------------------+
//| Process one Telegram message (may contain several signals)        |
//+------------------------------------------------------------------+
void ProcessMessage(string text, long msgId, long replyTo, string &replyText)
{
   string u=ToUpperAscii(text);
   if(IsSlMoveMsg(u)||IsCloseSignalMsg(u))
   {
      int idx=ResolveReplyTarget(replyTo,replyText);
      if(idx>=0) LogMsg("management reply matched its Telegram thread target (message "+IntegerToString(replyTo)+")");
      else idx=FindManagementTarget(u);
      if(idx<0) return;
      if(IsSlMoveMsg(u))
      {
         double x=ExtractSlMoveValue(u);
         if(x<=0.0) LogMsg("SL move requested but no number found in message - ignored");
         else ApplyMoveSlTo(idx,x);
      }
      if(IsCloseSignalMsg(u)) ApplyCloseSignal(idx);
      return;
   }
   int kw[];
   FindSignalKeywords(u,kw);
   if(ArraySize(kw)==0) return;
   for(int i=0;i<ArraySize(kw);i++)
   {
      int end=(i+1<ArraySize(kw)) ? kw[i+1] : StringLen(u);
      string chunk=StringSubstr(u,kw[i],end-kw[i]);
      Sig s;
      if(ParseSignal(chunk,s))
      {
         s.msgId=msgId;
         s.created=TimeCurrent();
         HandleSignal(s);
      }
      else
         LogMsg("found BUY/SELL keyword but text is not a complete signal (needs Entry:/TP/SL) - skipped");
   }
}

//+------------------------------------------------------------------+
//| Sync every OnTick: discover positions created when one of our    |
//| pending orders triggered, keep still-open pendings tracked,      |
//| auto-delete pendings that expired untriggered (InpMaxAgeMin),   |
//| and drop signals whose orders have all finished.                |
//+------------------------------------------------------------------+
void CleanupActive()
{
   for(int i=ArraySize(active)-1;i>=0;i--)
   {
      bool any=false;
      bool expired=(InpMaxAgeMin>0 && (long)TimeCurrent()-(long)active[i].created>(long)InpMaxAgeMin*60);
      for(int j=0;j<3;j++)
      {
         if(active[i].tp[j]<=0) continue;
         // known position ticket
         if(active[i].ticket[j]!=0)
         {
            if(PositionIsOpen(active[i].ticket[j])){ active[i].alive[j]=true; any=true; }
            else active[i].alive[j]=false;
            continue;
         }
         // pending placed but not a position yet: it may have triggered on the
         // broker between scans - look for its position first...
         ulong tk=FindTicket(active[i].symbol,active[i].side,active[i].tp[j]);
         if(tk!=0)
         {
            active[i].ticket[j]=tk;
            active[i].alive[j]=true;
            if(active[i].oticket[j]!=0)
               LogMsg("pending TP"+IntegerToString(j+1)+" TRIGGERED on "+active[i].symbol+" -> position ticket found");
            any=true;
            continue;
         }
         // ...or the pending is still waiting on the book
         ulong ot=OurOpenOrderTicket(active[i].symbol,active[i].side,active[i].tp[j]);
         if(ot!=0)
         {
            active[i].oticket[j]=ot;
            if(expired)
            {
               if(trade.OrderDelete(ot))
                  LogMsg("expired untriggered pending deleted ("+active[i].symbol+" TP"+IntegerToString(j+1)+")");
               active[i].oticket[j]=0;
               continue;   // counts as finished
            }
            any=true;   // pending still open: keep tracking the signal
            continue;
         }
         // nothing there: never placed / already closed or removed
         active[i].alive[j]=false;
      }
      if(!any)
      {
         LogMsg("signal fully closed/finished ("+active[i].symbol+") - removed from tracking");
         ArrayRemove(active,i,1);
      }
   }
}

//+------------------------------------------------------------------+
//| Expiry straight from the order book: in-memory signal tracking     |
//| (active[]) is lost whenever the EA is recompiled/re-attached or    |
//| when a second chart runs the EA - untriggered pendings placed     |
//| by an instance that has since died were never aged-checked, so    |
//| InpMaxAgeMin silently never fired. This scan goes to the book     |
//| itself: every open pending carrying our magic whose setup time    |
//| (ORDER_TIME_SETUP) is older than InpMaxAgeMin is deleted,         |
//| regardless of in-memory state. Orders still owned by a tracked    |
//| signal stay handled by CleanupActive (same rule, richer logging). |
//+------------------------------------------------------------------+
void ExpireOrphanPendings()
{
   if(InpMaxAgeMin<=0) return;
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      ulong tk=OrderGetTicket(i);
      if(tk==0) continue;
      if(OrderGetInteger(ORDER_MAGIC)!=InpMagic) continue;
      long ot=OrderGetInteger(ORDER_TYPE);
      bool pend=(ot==ORDER_TYPE_BUY_STOP||ot==ORDER_TYPE_SELL_STOP||ot==ORDER_TYPE_BUY_LIMIT||ot==ORDER_TYPE_SELL_LIMIT);
      if(!pend) continue;
      bool tracked=false;
      for(int a=0;a<ArraySize(active)&&!tracked;a++)
         for(int j=0;j<3&&!tracked;j++)
            if(active[a].oticket[j]==tk) tracked=true;
      if(tracked) continue;   // in-memory signal owns it: CleanupActive applies the same rule with full logging
      datetime born=(datetime)OrderGetInteger(ORDER_TIME_SETUP);
      if(born==0) continue;
      if((long)TimeCurrent()-(long)born>(long)InpMaxAgeMin*60)
         if(trade.OrderDelete(tk))
            LogMsg("expired untriggered pending deleted ("+OrderGetString(ORDER_SYMBOL)+")");
   }
}


//+------------------------------------------------------------------+
//| Trailing stops: while armed by OnTradeTransaction (after the     |
//| middle TP closed), the SL of the far order follows the current   |
//| price keeping trailDist of distance - but the value only ever   |
//| ratchets toward the profit side (never loosens).                |
//+------------------------------------------------------------------+
void ApplyTrailing()
{
   for(int i=0;i<ArraySize(active);i++)
   {
      string sym=active[i].symbol;
      int dg=SymbolDigits(sym);
      double pt=SymbolInfoDouble(sym,SYMBOL_POINT);
      for(int j=0;j<3;j++)
      {
         if(!active[i].trail[j]) continue;
         ulong tk=active[i].ticket[j];
         if(tk==0 || !PositionIsOpen(tk)) continue;
         double dist=active[i].trailDist;
         if(dist<=0.0) continue;
         double cur=(active[i].side>0) ? iBidPrice(sym,0) : iAskPrice(sym,0);
         double news=(active[i].side>0) ? cur-dist : cur+dist;
         // only tighten: BUY raises the SL, SELL lowers it (half-point step)
         if(active[i].side>0 && news<=active[i].trailv[j]+pt*0.5) continue;
         if(active[i].side<0 && news>=active[i].trailv[j]-pt*0.5) continue;
         if(trade.PositionModify(tk,news,active[i].tp[j]))
         {
            active[i].trailv[j]=news;
            LogMsg("TRAILING SL -> "+DoubleToString(news,dg)+" ("+sym+
                " TP"+IntegerToString(j+1)+" ticket "+IntegerToString((long)tk)+")");
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Telegram polling is GONE: the source of signals is exclusively    |
//| the Python bridge (bridge/telegram_to_mt5.py), which does the    |
//| Telegram authentication, watches the configured groups and        |
//| writes one JSON file per relevant message into                  |
//| <data folder>\MQL5\Files\<InpSignalsFolder>\. The EA only reads |
//| those files in ProcessSignalFiles() every InpPollSec seconds.    |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Bridge mode: signal files written by telegram_to_mt5.py.           |
//| Files live in <data folder>\MQL5\Files\<InpSignalsFolder>\*.json. |
//| Each file holds {"message_id":...,"date":...,"text":"..."}; the   |
//| the shared JSON parser (ExtractUpdates) is reused. Processed    |
//| files are MOVED to the 'consumed' subfolder (kept as history).  |
//+------------------------------------------------------------------+
string ReadFileToString(const string aPath)
{
   int fh=FileOpen(aPath,FILE_READ|FILE_TXT);
   if(fh==INVALID_HANDLE) return "";
   string s="";
   while(!FileIsEnding(fh))
      s+=FileReadString(fh)+"\n";   // JSON files are single-line (all real newlines are \u-escaped); the
   FileClose(fh);                    // extra "\n" is pure whitespace to the parser - harmless
   return s;
}

//+------------------------------------------------------------------+
//| Never delete a processed signal file: move it as-is into          |
//| <InpSignalsFolder>\consumed\ so every signal can be inspected.   |
//| Implemented with FileOpen/FileWriteString only (no FileCopy:    |
//| its parameter count varies across MQL5 builds).                  |
//+------------------------------------------------------------------+
bool MoveToConsumed(string aPath, string aName)
{
   string s=ReadFileToString(aPath);
   if(s=="")
   {
      LogMsg("consumed move: source unreadable ("+aName+") - deleted");
      return FileDelete(aPath);
   }
   string dst=InpSignalsFolder+"\\consumed\\"+aName;
   int fh=FileOpen(dst,FILE_WRITE|FILE_TXT);   // creates the folder when needed
   if(fh==INVALID_HANDLE)
   {
      LogMsg("consumed move: cannot create consumed\\"+aName+" - deleted");
      return FileDelete(aPath);
   }
   FileWriteString(fh,s);
   FileClose(fh);
   FileDelete(aPath);   // source gone: it now lives in consumed\
   return true;
}

void ProcessSignalFiles()
{
   string mask=InpSignalsFolder+"\\*.json";
   string name="";
   long sh=FileFindFirst(mask,name);   // current signature: (filter, &name, flag) -> handle
   int processed=0;
   if(sh!=INVALID_HANDLE)
   {
      do
      {
         // skip: hits in subfolders (FileFindFirst returns "consumed\xxx" - history)
         // and bridge temp files (".tmp_" = being renamed atomically right now)
         if(StringFind(name,"\\")>=0 || StringFind(name,".tmp_")==0)
            continue;
         string path=InpSignalsFolder+"\\"+name;
         string json=ReadFileToString(path);
         long ids[]; string texts[]; long replyIds[]; string replyTexts[];
         ExtractUpdates(json,ids,texts,replyIds,replyTexts);
         int n=ArraySize(texts);
         for(int i=0;i<n;i++)
         {
            long id=(ArraySize(ids)>i ? ids[i] : 0);
            if(id>g_lastMsgId) g_lastMsgId=id;
            long rt=(ArraySize(replyIds)>i ? replyIds[i] : 0);
            string rtx=(ArraySize(replyTexts)>i ? replyTexts[i] : "");
            ProcessMessage(texts[i],id,rt,rtx);
         }
         MoveToConsumed(path,name);   // moved to tg_signals\consumed\ , never deleted
         processed++;
      }
      while(processed<20 && FileFindNext(sh,name));   // (handle, &name) -> bool
      FileFindClose(sh);
   }
   if(processed>0)
   {
      LogMsg("bridge mode: processed "+IntegerToString(processed)+" signal file(s)");
      SaveLastId();
   }
}

//+------------------------------------------------------------------+
//| Persist last processed message id                                |
//+------------------------------------------------------------------+
void LoadLastId()
{
   int fh=FileOpen(InpStateFile,FILE_READ|FILE_TXT);
   if(fh!=INVALID_HANDLE)
   {
      string v=FileReadString(fh);
      g_lastMsgId=StringToInteger(v);
      FileClose(fh);
   }
}
void SaveLastId()
{
   int fh=FileOpen(InpStateFile,FILE_WRITE|FILE_TXT);
   if(fh!=INVALID_HANDLE)
   {
      FileWriteString(fh,IntegerToString(g_lastMsgId)+"\n");
      FileClose(fh);
   }
}

//+------------------------------------------------------------------+
//| Profitable TP close: the cascade you asked for -                 |
//| TP1 close -> SL of the rest moves to entry (breakeven);          |
//| TP2 close -> the farthest open order (TP3) also gets a TRAILING |
//| stop armed (ApplyTrailing follows the price).                    |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if((ENUM_TRADE_TRANSACTION_TYPE)trans.type!=TRADE_TRANSACTION_DEAL_ADD) return;
   long dealTicket=(long)trans.deal;
   if(dealTicket==0) return;
   if(HistoryDealGetInteger(dealTicket,DEAL_MAGIC)!=InpMagic) return;
   double profit=HistoryDealGetDouble(dealTicket,DEAL_PROFIT);
   if(profit<=0.0) return;   // closed at SL or manually with loss: do nothing
   ulong posId=(ulong)HistoryDealGetInteger(dealTicket,DEAL_POSITION_ID);
   if(posId==0) return;
   string sym=HistoryDealGetString(dealTicket,DEAL_SYMBOL);

   for(int i=0;i<ArraySize(active);i++)
   {
      if(active[i].symbol!=sym) continue;
      // claim positions created by our triggered pendings that CleanupActive
      // has not synced yet, so the breakeven move applies right away
      for(int j=0;j<3;j++)
         if(active[i].ticket[j]==0 && active[i].oticket[j]!=0)
         {
            ulong t2=FindTicket(active[i].symbol,active[i].side,active[i].tp[j]);
            if(t2!=0){ active[i].ticket[j]=t2; active[i].alive[j]=true; active[i].oticket[j]=0; }
         }
      int idx=-1;
      for(int j=0;j<3;j++)
         if(active[i].ticket[j]==posId && !active[i].done[j]) idx=j;
      if(idx<0) continue;

      active[i].done[idx]=true;
      active[i].alive[idx]=false;
      LogMsg("TP"+IntegerToString(idx+1)+" order closed with profit ("+sym+")");

      // move SL of the remaining open orders to their entry price first;
      // if the one that just closed was the MIDDLE TP (idx==1), arm a
      // trailing stop on the farthest open order (TP3) from that level.
      for(int j=0;j<3;j++)
      {
         if(j==idx || !active[i].alive[j]) continue;
         ulong tk=active[i].ticket[j];
         if(!PositionIsOpen(tk)) continue;
         double entry=PositionOpenPrice(tk);
         if(entry<=0) continue;
         if(InpConservativeMode && trade.PositionModify(tk,entry,active[i].tp[j]))
            LogMsg("CONSERVATIVE: SL of ticket "+IntegerToString((long)tk)+" moved to entry (breakeven) "+
                DoubleToString(entry,SymbolDigits(sym)));
         if(idx==1 && InpTrailPts!=0)
         {
            active[i].trail[j]=true;
            active[i].trailv[j]=entry;
            active[i].trailDist=(InpTrailPts>0)
               ? (double)InpTrailPts*SymbolInfoDouble(sym,SYMBOL_POINT)
               : MathAbs(entry-active[i].sl);   // auto: the signal's own risk distance
            LogMsg("TRAILING armed on "+sym+" TP"+IntegerToString(j+1)+
                " dist="+DoubleToString(active[i].trailDist,SymbolDigits(sym))+
                " (SL follows price from now on)");
         }
      }
      break;
   }
}

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpDevPoints);
   trade.SetTypeFilling(ORDER_FILLING_FOK);
   LoadLastId();
   Print((InpDryRun?"[TG-COPIER] DRY-RUN: no orders will be sent, the EA only logs what it would open.":"[TG-COPIER] LIVE: orders will be sent."));
   if(InpRiskPct>0) Print("[TG-COPIER] Lot sizing: risk "+DoubleToString(InpRiskPct,2)+"% of Balance per signal (lots clamped to [0.01..100]).");
   else             Print("[TG-COPIER] Lot sizing: fixed lots per category (InpLot*).");
   Print("[TG-COPIER] Conservative mode: "+(InpConservativeMode?"ON - remaining SLs move to breakeven when TP1 closes.":"OFF - original SLs stay when TP1 closes."));
   Print("[TG-COPIER] Channel replies handled: 'Moving SL to X' moves stops; 'Closing the signal' closes all if P/L>0, else shortens SLs to SMA("+IntegerToString(InpCloseMaPeriod)+") on the chart timeframe.");
   FolderCreate(InpSignalsFolder);   // best-effort: the bridge creates the folder too; if it does not
                                    // exist yet, a scan simply finds nothing
   // adopt positions already open with our magic (they keep their current SL/TP)
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong tk=PositionGetTicket(i);
      if(tk!=0 && PositionGetInteger(POSITION_MAGIC)==InpMagic)
         LogMsg("adopting existing open position ticket "+IntegerToString((long)tk));
   }
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert tick                                                      |
//+------------------------------------------------------------------+
void OnTick()
{
   if(TimeCurrent()>=g_nextPoll)
   {
      ProcessSignalFiles();   // scans MQL5\Files\<InpSignalsFolder> for new bridge JSONs
      g_nextPoll=TimeCurrent()+InpPollSec;
   }
   CleanupActive();
   ExpireOrphanPendings();   // order-book expiry: survives reloads & multi-chart
   ApplyTrailing();
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   SaveLastId();
}
//+------------------------------------------------------------------+
