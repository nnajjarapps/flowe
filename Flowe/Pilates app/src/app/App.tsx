import { useState } from "react";
import {
  Search, MapPin, Star, Clock, X, Check, Calendar, ArrowLeft,
  Video, UserCheck, Users, Heart, MessageCircle, Bookmark,
  MoreHorizontal, Compass, User, Flame, Award, Plus, Bell,
  Settings, ChevronRight, Wifi, Battery, Signal,
} from "lucide-react";

const SERIF = { fontFamily: "'Fraunces', Georgia, serif" };
const SANS  = { fontFamily: "'DM Sans', system-ui, sans-serif" };
const MONO  = { fontFamily: "'DM Mono', monospace" };

const PINK      = "#E8789A";
const PINK_DEEP = "#D45880";
const PINK_SOFT = "#F4A8C0";
const PINK_PALE = "#FFC2D4";
const WHITE     = "#FFFFFF";
const CARD_BG   = "#FFF0F4";
const DARK      = "#2D1520";
const MUTED     = "#B08090";
const BORDER    = "rgba(232,120,154,0.18)";
const GRAD      = "linear-gradient(135deg, #E8789A 0%, #F4A8C0 55%, #FFC2D4 100%)";
const GRAD_DARK = "linear-gradient(135deg, #D45880 0%, #E8789A 60%, #F4A8C0 100%)";

const instructors = [
  { id:1, name:"Sofia Marchetti", city:"New York, NY",  rating:4.9, reviews:112, price:95,  yearsExp:12, students:284, specialties:["Mat","Reformer","Tower"],  sessionTypes:["Private","Duet","Online"],  cert:"BASI Certified",  img:"1580489944761-15a19d654956", available:["Mon","Wed","Fri"]        },
  { id:2, name:"Elena Park",      city:"New York, NY",  rating:4.8, reviews:88,  price:85,  yearsExp:8,  students:197, specialties:["Prenatal","Rehab","Mat"],   sessionTypes:["Private","Group","Online"], cert:"PMA Certified",   img:"1573496359142-b8d87734a5a2", available:["Tue","Thu","Sat"]        },
  { id:3, name:"Margot Voss",     city:"Brooklyn, NY",  rating:4.9, reviews:64,  price:80,  yearsExp:5,  students:156, specialties:["Reformer","Barre","Mat"],   sessionTypes:["Private","Duet","Group"],   cert:"Stott Certified", img:"1607746882042-944635dfe10e", available:["Mon","Tue","Thu","Sat"]  },
  { id:4, name:"James Adler",     city:"Manhattan, NY", rating:4.7, reviews:45,  price:110, yearsExp:6,  students:98,  specialties:["Rehab","Tower","Mat"],      sessionTypes:["Private","Online"],         cert:"PhysioTrained",   img:"1472099645785-5658abf4ff4e", available:["Wed","Fri","Sun"]        },
  { id:5, name:"Camille Dubois",  city:"Hoboken, NJ",   rating:4.9, reviews:73,  price:90,  yearsExp:9,  students:142, specialties:["Mat","Tower","Reformer"],   sessionTypes:["Private","Duet","Group"],   cert:"Romana's Method", img:"1544005313-94ddf0286df2",    available:["Mon","Wed","Thu","Fri"]  },
  { id:6, name:"Priya Nair",      city:"Jersey City",   rating:4.8, reviews:51,  price:75,  yearsExp:7,  students:113, specialties:["Prenatal","Barre","Mat"],   sessionTypes:["Group","Online","Private"], cert:"BASI + Pre/Post", img:"1594824476967-48c8b964273f", available:["Tue","Wed","Sat","Sun"]  },
];

const feedPosts = [
  { id:1, type:"review",  user:"Mia Tanaka",    userImg:"1531746020798-e6953c6e8e04", instructor:"Sofia Marchetti", instImg:"1580489944761-15a19d654956", time:"2h ago", rating:5,    text:"Third session with Sofia and my lower back pain has genuinely disappeared. Her cueing is unlike anything I've experienced.", likes:34, comments:6,  saved:false, liked:false },
  { id:2, type:"tip",     user:"Elena Park",    userImg:"1573496359142-b8d87734a5a2", instructor:null,              instImg:null,                           time:"5h ago", rating:null, text:"Pilates tip: before you engage your powerhouse, find your exhale first. The breath is the engine — the core follows.", likes:89, comments:14, saved:true,  liked:true  },
  { id:3, type:"checkin", user:"James Okafor",  userImg:"1500648767791-00dcc994a43e", instructor:"Margot Voss",    instImg:"1607746882042-944635dfe10e", time:"8h ago", rating:null, text:"First reformer class done ✓  Margot's cues are so clear — even a complete beginner feels safe. Already booked session 2.", likes:21, comments:3,  saved:false, liked:false },
  { id:4, type:"tip",     user:"Camille Dubois",userImg:"1544005313-94ddf0286df2",    instructor:null,              instImg:null,                           time:"1d ago", rating:null, text:"Pilates was originally called Contrology — the complete control of your body. Every rep should be deliberate. Quality over count, always.", likes:142,comments:22, saved:false, liked:true  },
  { id:5, type:"review",  user:"Sara Mendes",   userImg:"1508214751196-bcfd4ca60f91", instructor:"Priya Nair",     instImg:"1594824476967-48c8b964273f", time:"2d ago", rating:5,    text:"Prenatal sessions with Priya have been the most grounding part of my third trimester. The breathwork alone is worth it.", likes:67, comments:9,  saved:true,  liked:false },
];

const DAYS  = ["Mon Jul 7","Tue Jul 8","Wed Jul 9","Thu Jul 10","Fri Jul 11","Sat Jul 12","Sun Jul 13"];
const TIMES = ["8:00 AM","9:00 AM","10:00 AM","11:00 AM","2:00 PM","3:30 PM","5:00 PM","6:00 PM"];

type Tab = "discover"|"community"|"bookings"|"profile";

// ── Status bar ────────────────────────────────────────────
function StatusBar() {
  return (
    <div className="relative flex items-center justify-between px-7 pt-4 pb-1 shrink-0" style={{ background: WHITE }}>
      <span className="text-[13px] font-semibold" style={{ ...MONO, color: DARK }}>9:41</span>
      <div className="absolute left-1/2 -translate-x-1/2 top-3 w-[120px] h-[35px] rounded-full" style={{ background: "#000" }} />
      <div className="flex items-center gap-[5px]">
        <Signal size={13} style={{ color: DARK }} />
        <Wifi   size={13} style={{ color: DARK }} />
        <Battery size={13} style={{ color: DARK }} />
      </div>
    </div>
  );
}

// ── Bottom tab bar ────────────────────────────────────────
function TabBar({ tab, setTab }: { tab: Tab; setTab: (t: Tab) => void }) {
  const tabs = [
    { id:"discover"  as Tab, icon:<Compass  size={22}/>, label:"Discover"   },
    { id:"community" as Tab, icon:<Users    size={22}/>, label:"Community"  },
    { id:"bookings"  as Tab, icon:<Calendar size={22}/>, label:"Bookings"   },
    { id:"profile"   as Tab, icon:<User     size={22}/>, label:"Profile"    },
  ];
  return (
    <div className="shrink-0" style={{ background: WHITE, borderTop: `1px solid ${BORDER}` }}>
      <div className="flex">
        {tabs.map(t => (
          <button key={t.id} onClick={() => setTab(t.id)}
            className="flex-1 flex flex-col items-center pt-2 pb-1 gap-0.5 transition-colors"
            style={{ color: tab === t.id ? PINK_DEEP : MUTED }}>
            {t.icon}
            <span className="text-[10px] font-medium" style={SANS}>{t.label}</span>
          </button>
        ))}
      </div>
      <div className="flex justify-center pb-2 pt-0.5">
        <div className="w-28 h-1 rounded-full" style={{ background: BORDER }} />
      </div>
    </div>
  );
}

// ── Discover ──────────────────────────────────────────────
function DiscoverScreen({ onSelect }: { onSelect: (i: typeof instructors[0]) => void }) {
  const [search, setSearch] = useState("");
  const [filter, setFilter] = useState("All");
  const cats = ["All","Mat","Reformer","Barre","Tower","Prenatal","Rehab"];
  const list = instructors.filter(i =>
    (filter === "All" || i.specialties.includes(filter)) &&
    (search === "" || i.name.toLowerCase().includes(search.toLowerCase()) || i.city.toLowerCase().includes(search.toLowerCase()))
  );

  return (
    <div className="flex-1 overflow-y-auto" style={{ background: WHITE }}>
      {/* Header */}
      <div className="px-5 pt-3 pb-3">
        <div className="flex items-center justify-between mb-4">
          <div>
            <p className="text-[11px] font-medium" style={{ ...MONO, color: PINK_DEEP }}>GOOD MORNING</p>
            <h1 className="text-[22px] font-normal leading-tight" style={{ ...SERIF, color: DARK }}>
              Find your <em>instructor.</em>
            </h1>
          </div>
          <button className="w-9 h-9 rounded-full flex items-center justify-center"
            style={{ background: CARD_BG, border: `1px solid ${BORDER}` }}>
            <Bell size={16} style={{ color: DARK }} />
          </button>
        </div>
        <div className="flex items-center gap-2.5 rounded-2xl px-3.5 py-2.5"
          style={{ background: CARD_BG, border: `1px solid ${BORDER}` }}>
          <Search size={15} style={{ color: MUTED }} />
          <input className="flex-1 bg-transparent text-[14px] outline-none"
            style={{ ...SANS, color: DARK }} placeholder="Name or city…"
            value={search} onChange={e => setSearch(e.target.value)} />
          {search && <button onClick={() => setSearch("")}><X size={13} style={{ color: MUTED }} /></button>}
        </div>
      </div>

      {/* Category chips */}
      <div className="flex gap-2 px-5 pb-4 overflow-x-auto" style={{ scrollbarWidth:"none" }}>
        {cats.map(c => (
          <button key={c} onClick={() => setFilter(c)}
            className="shrink-0 px-3.5 py-1.5 rounded-full text-[12px] font-medium transition-all"
            style={{
              ...SANS,
              background: filter === c ? GRAD_DARK : CARD_BG,
              color:      filter === c ? WHITE : DARK,
              border:     `1px solid ${filter === c ? "transparent" : BORDER}`,
            }}>{c}</button>
        ))}
      </div>

      {/* Featured hero card */}
      {filter === "All" && !search && (
        <div className="px-5 mb-5">
          <p className="text-[11px] font-medium mb-2.5" style={{ ...MONO, color: MUTED }}>FEATURED</p>
          <button onClick={() => onSelect(instructors[0])} className="w-full rounded-3xl overflow-hidden relative block" style={{ height:200 }}>
            <img src="https://images.unsplash.com/photo-1518611012118-696072aa579a?w=700&h=400&fit=crop&auto=format"
              alt="Pilates reformer" className="w-full h-full object-cover" />
            <div className="absolute inset-0" style={{ background:"linear-gradient(to top, rgba(212,88,128,0.75) 0%, rgba(232,120,154,0.2) 60%, transparent 100%)" }} />
            <div className="absolute bottom-0 left-0 right-0 p-4">
              <div className="flex items-center gap-1 mb-1">
                <Star size={11} fill="white" stroke="white" />
                <span className="text-white text-[11px]" style={MONO}>4.9 · 112 reviews</span>
              </div>
              <p className="text-white text-[18px] font-normal" style={SERIF}>Sofia Marchetti</p>
              <p className="text-white/85 text-[12px] flex items-center gap-1" style={SANS}>
                <MapPin size={11} />New York · Mat · Reformer · Tower
              </p>
            </div>
            <div className="absolute top-3 right-3 px-2.5 py-1 rounded-full"
              style={{ background:"rgba(255,255,255,0.25)", backdropFilter:"blur(8px)" }}>
              <span className="text-white text-[12px] font-medium" style={SANS}>$95/session</span>
            </div>
          </button>
        </div>
      )}

      {/* List */}
      <div className="px-5 pb-6">
        <p className="text-[11px] font-medium mb-2.5" style={{ ...MONO, color: MUTED }}>
          {filter === "All" ? "NEAR YOU" : filter.toUpperCase()} · {list.length} INSTRUCTORS
        </p>
        <div className="flex flex-col gap-3">
          {list.map(ins => (
            <button key={ins.id} onClick={() => onSelect(ins)}
              className="w-full text-left rounded-2xl overflow-hidden flex"
              style={{ background: CARD_BG, border: `1px solid ${BORDER}` }}>
              <div className="relative w-[88px] shrink-0" style={{ background: PINK_PALE }}>
                <div className="absolute inset-0" style={{ background: GRAD, opacity: 0.35 }} />
                <img src={`https://images.unsplash.com/photo-${ins.img}?w=160&h=160&fit=crop&auto=format`}
                  alt={ins.name} className="w-full h-full object-cover" />
              </div>
              <div className="flex-1 p-3">
                <div className="flex items-start justify-between mb-0.5">
                  <p className="text-[15px] font-normal leading-tight" style={{ ...SERIF, color: DARK }}>{ins.name}</p>
                  <div className="flex items-center gap-0.5 ml-2 shrink-0">
                    <Star size={10} fill={PINK} stroke={PINK} />
                    <span className="text-[11px]" style={{ ...MONO, color: PINK_DEEP }}>{ins.rating}</span>
                  </div>
                </div>
                <p className="text-[11px] flex items-center gap-1 mb-2" style={{ ...SANS, color: MUTED }}>
                  <MapPin size={10} />{ins.city}
                </p>
                <div className="flex items-center gap-1 flex-wrap mb-2">
                  {ins.specialties.slice(0,2).map(s => (
                    <span key={s} className="text-[10px] px-2 py-0.5 rounded-full"
                      style={{ ...MONO, background: PINK+"18", color: PINK_DEEP }}>{s}</span>
                  ))}
                </div>
                <div className="flex items-center justify-between">
                  <span className="text-[11px]" style={{ ...MONO, color: MUTED }}>{ins.sessionTypes.slice(0,2).join(" · ")}</span>
                  <span className="text-[13px] font-medium" style={{ ...SERIF, color: DARK }}>${ins.price}</span>
                </div>
              </div>
            </button>
          ))}
        </div>
      </div>
    </div>
  );
}

// ── Community ─────────────────────────────────────────────
function CommunityScreen() {
  const [posts, setPosts] = useState(feedPosts);
  const toggle = (id: number, field: "liked"|"saved") =>
    setPosts(p => p.map(post => post.id === id
      ? { ...post, [field]: !post[field], likes: field === "liked" ? post.likes + (post.liked ? -1 : 1) : post.likes }
      : post));

  return (
    <div className="flex-1 overflow-y-auto" style={{ background: WHITE }}>
      <div className="px-5 pt-3 pb-3 flex items-center justify-between"
        style={{ borderBottom: `1px solid ${BORDER}` }}>
        <h1 className="text-[20px] font-normal" style={{ ...SERIF, color: DARK }}>Community</h1>
        <button className="w-8 h-8 rounded-full flex items-center justify-center"
          style={{ background: GRAD_DARK }}>
          <Plus size={16} color="white" />
        </button>
      </div>

      {/* Stories */}
      <div className="flex gap-3 px-5 py-3 overflow-x-auto" style={{ scrollbarWidth:"none", borderBottom:`1px solid ${BORDER}` }}>
        {instructors.slice(0,5).map(ins => (
          <div key={ins.id} className="shrink-0 flex flex-col items-center gap-1">
            <div className="w-[52px] h-[52px] rounded-full p-[2.5px]" style={{ background: GRAD_DARK }}>
              <div className="w-full h-full rounded-full overflow-hidden" style={{ border:`2px solid ${WHITE}` }}>
                <img src={`https://images.unsplash.com/photo-${ins.img}?w=80&h=80&fit=crop&auto=format`}
                  alt={ins.name} className="w-full h-full object-cover" />
              </div>
            </div>
            <p className="text-[9px] text-center w-12 truncate" style={{ ...SANS, color: DARK }}>
              {ins.name.split(" ")[0]}
            </p>
          </div>
        ))}
      </div>

      {/* Feed */}
      {posts.map(post => (
        <div key={post.id} style={{ borderBottom: `1px solid ${BORDER}` }}>
          <div className="flex items-center gap-2.5 px-4 pt-3.5 pb-2">
            <div className="w-9 h-9 rounded-full overflow-hidden shrink-0"
              style={{ background: PINK_PALE }}>
              <img src={`https://images.unsplash.com/photo-${post.userImg}?w=72&h=72&fit=crop&auto=format`}
                alt={post.user} className="w-full h-full object-cover" />
            </div>
            <div className="flex-1 min-w-0">
              <p className="text-[13px] font-medium leading-tight" style={{ ...SANS, color: DARK }}>{post.user}</p>
              <p className="text-[11px]" style={{ ...MONO, color: MUTED }}>
                {post.type === "review" ? `reviewed ${post.instructor}` :
                 post.type === "checkin" ? `checked in with ${post.instructor}` : "shared a tip"} · {post.time}
              </p>
            </div>
            <button><MoreHorizontal size={16} style={{ color: MUTED }} /></button>
          </div>

          {post.instImg && (
            <div className="mx-4 mb-2 rounded-xl overflow-hidden relative" style={{ height:140 }}>
              <div className="absolute inset-0" style={{ background: GRAD, opacity: 0.5 }} />
              <img src={`https://images.unsplash.com/photo-${post.instImg}?w=600&h=280&fit=crop&auto=format`}
                alt={post.instructor!} className="w-full h-full object-cover" style={{ mixBlendMode:"multiply" }} />
              {post.rating && (
                <div className="absolute top-2.5 right-2.5 flex items-center gap-0.5 px-2 py-1 rounded-full"
                  style={{ background:"rgba(255,255,255,0.3)", backdropFilter:"blur(8px)" }}>
                  {[...Array(post.rating)].map((_,i) => <Star key={i} size={9} fill="white" stroke="white" />)}
                </div>
              )}
            </div>
          )}

          <p className="px-4 pb-2 text-[13px] leading-relaxed" style={{ ...SANS, color: DARK }}>{post.text}</p>

          {post.type === "tip" && (
            <div className="mx-4 mb-3 px-3 py-2 rounded-xl flex items-center gap-2"
              style={{ background: PINK+"12", border:`1px solid ${PINK}30` }}>
              <Flame size={13} style={{ color: PINK_DEEP }} />
              <span className="text-[11px] font-medium" style={{ ...SANS, color: PINK_DEEP }}>Instructor Tip</span>
            </div>
          )}

          <div className="flex items-center gap-4 px-4 pb-3.5">
            <button onClick={() => toggle(post.id, "liked")} className="flex items-center gap-1.5">
              <Heart size={17} fill={post.liked ? PINK : "none"} stroke={post.liked ? PINK : MUTED} />
              <span className="text-[12px]" style={{ ...SANS, color: post.liked ? PINK : MUTED }}>{post.likes}</span>
            </button>
            <button className="flex items-center gap-1.5">
              <MessageCircle size={17} style={{ color: MUTED }} />
              <span className="text-[12px]" style={{ ...SANS, color: MUTED }}>{post.comments}</span>
            </button>
            <div className="flex-1" />
            <button onClick={() => toggle(post.id, "saved")}>
              <Bookmark size={17} fill={post.saved ? PINK_DEEP : "none"} stroke={post.saved ? PINK_DEEP : MUTED} />
            </button>
          </div>
        </div>
      ))}
    </div>
  );
}

// ── Bookings ──────────────────────────────────────────────
function BookingsScreen({ onSelect }: { onSelect: (i: typeof instructors[0]) => void }) {
  const [bTab, setBTab] = useState<"upcoming"|"past">("upcoming");
  const upcoming = [
    { id:1, instructorId:1, date:"Thu, Jul 10", time:"9:00 AM",  type:"Private", duration:"55 min", status:"confirmed" },
    { id:2, instructorId:3, date:"Sat, Jul 12", time:"11:00 AM", type:"Duet",    duration:"50 min", status:"pending"   },
  ];
  const past = [
    { id:3, instructorId:2, date:"Thu, Jul 3",  time:"10:00 AM", type:"Online",  duration:"50 min", status:"completed" },
    { id:4, instructorId:1, date:"Mon, Jun 28", time:"9:00 AM",  type:"Private", duration:"55 min", status:"completed" },
    { id:5, instructorId:5, date:"Fri, Jun 20", time:"8:00 AM",  type:"Private", duration:"55 min", status:"cancelled" },
  ];
  const list = bTab === "upcoming" ? upcoming : past;

  const badge = (s: string) => ({
    confirmed: { bg: "#E8F5E9", color: "#4CAF50", label:"Confirmed" },
    pending:   { bg: PINK+"18", color: PINK_DEEP, label:"Pending"   },
    completed: { bg: CARD_BG,   color: MUTED,     label:"Done"      },
    cancelled: { bg: "#FFF0F0", color: "#E05070", label:"Cancelled" },
  }[s] ?? { bg: CARD_BG, color: MUTED, label: s });

  return (
    <div className="flex-1 overflow-y-auto" style={{ background: WHITE }}>
      <div className="px-5 pt-3">
        <h1 className="text-[20px] font-normal mb-4" style={{ ...SERIF, color: DARK }}>My <em>Sessions</em></h1>
        <div className="grid grid-cols-3 gap-2 mb-5">
          {[
            { label:"Upcoming", val:2,     color: PINK_DEEP },
            { label:"Completed",val:2,     color: "#4CAF50" },
            { label:"Hours",    val:"6.5", color: PINK_SOFT },
          ].map(s => (
            <div key={s.label} className="rounded-2xl p-3 text-center"
              style={{ background: s.color+"10", border:`1px solid ${s.color}25` }}>
              <p className="text-[20px] font-medium" style={{ ...SERIF, color: s.color }}>{s.val}</p>
              <p className="text-[10px]" style={{ ...MONO, color: MUTED }}>{s.label}</p>
            </div>
          ))}
        </div>
        <div className="flex rounded-xl p-0.5 mb-5" style={{ background: CARD_BG }}>
          {(["upcoming","past"] as const).map(t => (
            <button key={t} onClick={() => setBTab(t)}
              className="flex-1 py-2 rounded-lg text-[12px] font-medium capitalize transition-all"
              style={{
                ...SANS,
                background: bTab === t ? WHITE : "transparent",
                color: bTab === t ? DARK : MUTED,
                boxShadow: bTab === t ? "0 1px 3px rgba(232,120,154,0.15)" : "none",
              }}>{t}</button>
          ))}
        </div>
      </div>

      <div className="px-5 pb-6 flex flex-col gap-3">
        {list.map(b => {
          const ins = instructors.find(i => i.id === b.instructorId)!;
          const bd  = badge(b.status);
          return (
            <div key={b.id} className="rounded-2xl overflow-hidden"
              style={{ background: CARD_BG, border:`1px solid ${BORDER}` }}>
              <div className="relative h-[68px]" style={{ background: PINK_PALE }}>
                <div className="absolute inset-0" style={{ background: GRAD, opacity: 0.5 }} />
                <img src={`https://images.unsplash.com/photo-${ins.img}?w=600&h=136&fit=crop&auto=format`}
                  alt={ins.name} className="w-full h-full object-cover object-top"
                  style={{ mixBlendMode:"multiply", opacity:0.6 }} />
                <div className="absolute inset-0 flex items-center px-4 gap-3">
                  <div className="w-10 h-10 rounded-full overflow-hidden shrink-0"
                    style={{ border:`2px solid rgba(255,255,255,0.5)`, background: PINK_PALE }}>
                    <img src={`https://images.unsplash.com/photo-${ins.img}?w=80&h=80&fit=crop&auto=format`}
                      alt={ins.name} className="w-full h-full object-cover" />
                  </div>
                  <div>
                    <p className="text-white text-[14px] font-medium" style={SERIF}>{ins.name}</p>
                    <p className="text-white/80 text-[11px]" style={MONO}>{b.type} · {b.duration}</p>
                  </div>
                  <span className="ml-auto text-[10px] font-medium px-2.5 py-1 rounded-full"
                    style={{ ...MONO, background: bd.bg, color: bd.color }}>{bd.label}</span>
                </div>
              </div>
              <div className="px-4 py-3 flex items-center justify-between">
                <div className="flex items-center gap-3">
                  <span className="flex items-center gap-1.5 text-[12px]" style={{ ...SANS, color: DARK }}>
                    <Calendar size={12} style={{ color: MUTED }} />{b.date}
                  </span>
                  <span className="flex items-center gap-1.5 text-[12px]" style={{ ...SANS, color: DARK }}>
                    <Clock size={12} style={{ color: MUTED }} />{b.time}
                  </span>
                </div>
                {b.status === "completed"
                  ? <button onClick={() => onSelect(ins)} className="text-[11px]" style={{ ...SANS, color: PINK_DEEP }}>Book again</button>
                  : <button className="text-[11px]" style={{ ...SANS, color: MUTED }}>Cancel</button>}
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
}

// ── Profile ───────────────────────────────────────────────
function ProfileScreen() {
  const bars = [{d:"M",v:55},{d:"T",v:0},{d:"W",v:60},{d:"T",v:55},{d:"F",v:45},{d:"S",v:50},{d:"S",v:0}];
  return (
    <div className="flex-1 overflow-y-auto" style={{ background: WHITE }}>
      <div className="px-5 pt-4 pb-4 flex items-center gap-4" style={{ borderBottom:`1px solid ${BORDER}` }}>
        <div className="w-16 h-16 rounded-full overflow-hidden shrink-0" style={{ background: PINK_PALE }}>
          <img src="https://images.unsplash.com/photo-1531746020798-e6953c6e8e04?w=128&h=128&fit=crop&auto=format"
            alt="Mia Tanaka" className="w-full h-full object-cover" />
        </div>
        <div className="flex-1">
          <h2 className="text-[19px] font-normal" style={{ ...SERIF, color: DARK }}>Mia Tanaka</h2>
          <p className="text-[12px]" style={{ ...SANS, color: MUTED }}>Member since March 2026</p>
          <div className="flex items-center gap-1 mt-1">
            <span className="text-[10px] px-2 py-0.5 rounded-full" style={{ ...MONO, background: PINK+"18", color: PINK_DEEP }}>Reformer</span>
            <span className="text-[10px] px-2 py-0.5 rounded-full" style={{ ...MONO, background: PINK_SOFT+"30", color: PINK_DEEP }}>Mat</span>
          </div>
        </div>
        <button className="w-8 h-8 rounded-full flex items-center justify-center"
          style={{ background: CARD_BG, border:`1px solid ${BORDER}` }}>
          <Settings size={15} style={{ color: DARK }} />
        </button>
      </div>

      <div className="px-5 pt-4">
        <p className="text-[11px] font-medium mb-3" style={{ ...MONO, color: MUTED }}>YOUR PROGRESS</p>
        <div className="grid grid-cols-3 gap-2 mb-5">
          {[
            { icon:<Flame size={16} style={{ color: PINK_DEEP }} />, label:"9-day streak",  sub:"Best: 18" },
            { icon:<Award size={16} style={{ color: PINK }}      />, label:"14 sessions",   sub:"This month" },
            { icon:<Star  size={16} style={{ color: PINK_SOFT }} />, label:"5 instructors", sub:"Worked with" },
          ].map(a => (
            <div key={a.label} className="rounded-2xl p-3 flex flex-col items-center text-center"
              style={{ background: CARD_BG, border:`1px solid ${BORDER}` }}>
              <div className="mb-1.5">{a.icon}</div>
              <p className="text-[12px] font-medium leading-tight" style={{ ...SANS, color: DARK }}>{a.label}</p>
              <p className="text-[10px] mt-0.5" style={{ ...MONO, color: MUTED }}>{a.sub}</p>
            </div>
          ))}
        </div>

        <p className="text-[11px] font-medium mb-2.5" style={{ ...MONO, color: MUTED }}>THIS WEEK</p>
        <div className="rounded-2xl p-4 mb-5" style={{ background: CARD_BG, border:`1px solid ${BORDER}` }}>
          <div className="flex items-end justify-between gap-1.5" style={{ height:56 }}>
            {bars.map(b => (
              <div key={b.d} className="flex-1 flex flex-col items-center gap-1">
                <div className="w-full rounded-t-md"
                  style={{ height: b.v > 0 ? (b.v/60)*44 : 3, background: b.v > 0 ? GRAD_DARK : BORDER }} />
                <span className="text-[9px]" style={{ ...MONO, color: MUTED }}>{b.d}</span>
              </div>
            ))}
          </div>
          <p className="text-[11px] mt-2" style={{ ...SANS, color: MUTED }}>
            <span style={{ color: DARK, fontWeight:500 }}>265 min</span> practiced this week
          </p>
        </div>

        <p className="text-[11px] font-medium mb-2.5" style={{ ...MONO, color: MUTED }}>ACCOUNT</p>
        <div className="rounded-2xl overflow-hidden mb-6" style={{ border:`1px solid ${BORDER}` }}>
          {["Notifications","Payment methods","Privacy","Help & Support","Log out"].map((s, i) => (
            <button key={s} className="w-full flex items-center justify-between px-4 py-3.5 text-left"
              style={{
                background: WHITE,
                borderTop: i > 0 ? `1px solid ${BORDER}` : "none",
                color: s === "Log out" ? PINK_DEEP : DARK,
              }}>
              <span className="text-[14px]" style={SANS}>{s}</span>
              {s !== "Log out" && <ChevronRight size={15} style={{ color: MUTED }} />}
            </button>
          ))}
        </div>
      </div>
    </div>
  );
}

// ── Booking sheet ─────────────────────────────────────────
function BookingSheet({ ins, onClose }: { ins: typeof instructors[0]; onClose: () => void }) {
  const [step, setStep]     = useState(0);
  const [day, setDay]       = useState("");
  const [time, setTime]     = useState("");
  const [type, setType]     = useState(ins.sessionTypes[0]);
  const typeIcon = (t: string) => t === "Online" ? <Video size={12}/> : t === "Private" ? <UserCheck size={12}/> : <Users size={12}/>;

  return (
    <div className="absolute inset-0 z-40 flex flex-col justify-end"
      style={{ background:"rgba(45,21,32,0.45)", backdropFilter:"blur(4px)" }}>
      <div className="rounded-t-3xl flex flex-col" style={{ background: WHITE, maxHeight:"90%" }}>
        <div className="flex justify-center pt-3 pb-1 shrink-0">
          <div className="w-10 h-1 rounded-full" style={{ background: BORDER }} />
        </div>

        {/* Hero */}
        <div className="relative h-36 shrink-0 mx-4 rounded-2xl overflow-hidden mb-4">
          <div className="absolute inset-0" style={{ background: GRAD, opacity:0.7 }} />
          <img src={`https://images.unsplash.com/photo-${ins.img}?w=600&h=280&fit=crop&auto=format`}
            alt={ins.name} className="w-full h-full object-cover" style={{ mixBlendMode:"multiply" }} />
          <div className="absolute inset-0" style={{ background:"linear-gradient(to top,rgba(0,0,0,0.35) 0%,transparent 60%)" }} />
          <button onClick={onClose}
            className="absolute top-3 right-3 w-7 h-7 rounded-full flex items-center justify-center"
            style={{ background:"rgba(255,255,255,0.25)", backdropFilter:"blur(8px)" }}>
            <X size={13} color="white" />
          </button>
          <div className="absolute bottom-3 left-4 right-4 flex items-end justify-between">
            <div>
              <p className="text-white text-[17px] font-normal" style={SERIF}>{ins.name}</p>
              <p className="text-white/75 text-[11px] flex items-center gap-1" style={MONO}><MapPin size={10}/>{ins.city}</p>
            </div>
            <div className="flex items-center gap-1 px-2.5 py-1 rounded-full"
              style={{ background:"rgba(255,255,255,0.25)", backdropFilter:"blur(8px)" }}>
              <Star size={10} fill="white" stroke="white"/>
              <span className="text-white text-[11px]" style={MONO}>{ins.rating} ({ins.reviews})</span>
            </div>
          </div>
        </div>

        <div className="overflow-y-auto px-4 pb-6" style={{ flex:1 }}>
          {step === 0 && (
            <>
              <div className="flex gap-4 mb-4 pb-4" style={{ borderBottom:`1px solid ${BORDER}` }}>
                {[{l:"Students",v:ins.students},{l:"Exp.",v:ins.yearsExp+"yrs"},{l:"Reviews",v:ins.reviews}].map(s=>(
                  <div key={s.l} className="flex-1 text-center">
                    <p className="text-[18px] font-medium" style={{...SERIF,color:DARK}}>{s.v}</p>
                    <p className="text-[9px]" style={{...MONO,color:MUTED}}>{s.l}</p>
                  </div>
                ))}
              </div>
              <p className="text-[13px] leading-relaxed mb-4" style={{...SANS,color:DARK}}>{ins.bio ?? "Certified Pilates instructor."}</p>
              <div className="flex flex-wrap gap-1.5 mb-5">
                {ins.specialties.map(s=>(
                  <span key={s} className="text-[11px] px-2.5 py-1 rounded-full"
                    style={{...MONO,background:PINK+"15",color:PINK_DEEP}}>{s}</span>
                ))}
              </div>
              <button onClick={()=>setStep(1)} className="w-full py-3.5 rounded-2xl text-[15px] font-medium text-white"
                style={{...SANS,background:GRAD_DARK}}>
                Book a Session · ${ins.price}
              </button>
            </>
          )}

          {step === 1 && (
            <>
              <div className="flex items-center gap-2 mb-3">
                <button onClick={()=>setStep(0)}><ArrowLeft size={18} style={{color:DARK}}/></button>
                <h3 className="text-[17px] font-normal" style={{...SERIF,color:DARK}}>Choose a day</h3>
              </div>
              <p className="text-[11px] mb-3" style={{...MONO,color:MUTED}}>Available: {ins.available.join(", ")}</p>
              <div className="grid grid-cols-4 gap-2 mb-5">
                {DAYS.map(d=>{
                  const avail = ins.available.includes(d.slice(0,3));
                  const sel   = day === d;
                  return (
                    <button key={d} disabled={!avail} onClick={()=>setDay(d)}
                      className="py-3 rounded-xl text-center transition-all"
                      style={{
                        background: sel ? GRAD_DARK : avail ? CARD_BG : BORDER+"40",
                        border: `1px solid ${sel ? "transparent" : avail ? BORDER : BORDER+"40"}`,
                        opacity: avail ? 1 : 0.35,
                      }}>
                      <span className="block text-[10px] font-medium" style={{...MONO,color:sel?"white":DARK}}>{d.slice(0,3)}</span>
                      <span className="block text-[11px]" style={{color:sel?"white":DARK}}>{d.slice(4)}</span>
                    </button>
                  );
                })}
              </div>
              <button disabled={!day} onClick={()=>setStep(2)}
                className="w-full py-3.5 rounded-2xl text-[15px] font-medium text-white disabled:opacity-30"
                style={{...SANS,background:GRAD_DARK}}>
                Continue
              </button>
            </>
          )}

          {step === 2 && (
            <>
              <div className="flex items-center gap-2 mb-1">
                <button onClick={()=>setStep(1)}><ArrowLeft size={18} style={{color:DARK}}/></button>
                <h3 className="text-[17px] font-normal" style={{...SERIF,color:DARK}}>Time & type</h3>
              </div>
              <p className="text-[11px] mb-3" style={{...MONO,color:MUTED}}>{day}</p>
              <div className="grid grid-cols-4 gap-2 mb-4">
                {TIMES.map(t=>(
                  <button key={t} onClick={()=>setTime(t)}
                    className="py-2.5 rounded-xl text-[11px] text-center transition-all"
                    style={{...MONO,background:time===t?GRAD_DARK:CARD_BG,border:`1px solid ${time===t?"transparent":BORDER}`,color:time===t?"white":DARK}}>
                    {t}
                  </button>
                ))}
              </div>
              <p className="text-[11px] mb-2" style={{...MONO,color:MUTED}}>SESSION TYPE</p>
              <div className="flex gap-2 mb-5">
                {ins.sessionTypes.map(t=>(
                  <button key={t} onClick={()=>setType(t)}
                    className="flex-1 flex items-center justify-center gap-1.5 py-2.5 rounded-xl text-[12px] transition-all"
                    style={{...SANS,background:type===t?GRAD_DARK:CARD_BG,border:`1px solid ${type===t?"transparent":BORDER}`,color:type===t?"white":MUTED}}>
                    {typeIcon(t)}{t}
                  </button>
                ))}
              </div>
              <button disabled={!time} onClick={()=>setStep(3)}
                className="w-full py-3.5 rounded-2xl text-[15px] font-medium text-white disabled:opacity-30"
                style={{...SANS,background:GRAD_DARK}}>
                Confirm · ${ins.price}
              </button>
            </>
          )}

          {step === 3 && (
            <div className="text-center py-4">
              <div className="w-16 h-16 rounded-full flex items-center justify-center mx-auto mb-4"
                style={{background:GRAD_DARK}}>
                <Check size={28} color="white" />
              </div>
              <h3 className="text-[22px] font-normal mb-1" style={{...SERIF,color:DARK}}>You're booked!</h3>
              <p className="text-[14px] mb-1" style={{...SANS,color:DARK}}>{ins.name} · {type}</p>
              <p className="text-[12px] mb-5" style={{...MONO,color:MUTED}}>{day} at {time}</p>
              <div className="rounded-2xl p-4 mb-5" style={{background:CARD_BG,border:`1px solid ${BORDER}`}}>
                {[["Session fee",`$${ins.price}`],["Service fee","$9"],["Total",`$${ins.price+9}`]].map(([l,v],i)=>(
                  <div key={l} className={`flex items-center justify-between text-[13px] ${i===2?"font-medium pt-3 mt-2":"mt-1"}`}
                    style={{...SANS,color:DARK,borderTop:i===2?`1px solid ${BORDER}`:"none"}}>
                    <span style={{color:i===2?DARK:MUTED}}>{l}</span><span>{v}</span>
                  </div>
                ))}
              </div>
              <button onClick={onClose} className="w-full py-3.5 rounded-2xl text-[15px] font-medium text-white"
                style={{...SANS,background:GRAD_DARK}}>
                Done
              </button>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}

// ── Root ──────────────────────────────────────────────────
export default function App() {
  const [tab, setTab]     = useState<Tab>("discover");
  const [sheet, setSheet] = useState<typeof instructors[0]|null>(null);

  return (
    <div className="min-h-screen flex items-center justify-center p-8"
      style={{ background:"radial-gradient(ellipse at 30% 20%, #fce4ec 0%, #f8bbd0 40%, #f48fb1 100%)" }}>

      {/* Device */}
      <div className="relative" style={{ width:393 }}>
        {/* Shell */}
        <div className="relative rounded-[54px]"
          style={{
            padding: 3,
            background:"linear-gradient(160deg, #e0e0e0 0%, #bdbdbd 40%, #d0d0d0 100%)",
            boxShadow:[
              "0 0 0 1px #c0c0c0",
              "0 50px 100px rgba(212,88,128,0.35)",
              "0 20px 40px rgba(0,0,0,0.25)",
              "inset 0 1px 0 rgba(255,255,255,0.6)",
            ].join(", "),
          }}>

          {/* Buttons */}
          <div className="absolute rounded-l-sm" style={{ left:-3, top:130, width:3, height:30, background:"#bdbdbd" }} />
          <div className="absolute rounded-l-sm" style={{ left:-3, top:178, width:3, height:58, background:"#bdbdbd" }} />
          <div className="absolute rounded-l-sm" style={{ left:-3, top:248, width:3, height:58, background:"#bdbdbd" }} />
          <div className="absolute rounded-r-sm" style={{ right:-3, top:178, width:3, height:82, background:"#bdbdbd" }} />

          {/* Screen */}
          <div className="rounded-[52px] overflow-hidden" style={{ background:"#000" }}>
            <div style={{ width:387, height:852, overflow:"hidden", position:"relative", background:WHITE }}>
              <div className="flex flex-col h-full">
                <StatusBar />
                <div className="flex-1 overflow-hidden flex flex-col relative">
                  {tab === "discover"  && <DiscoverScreen  onSelect={setSheet} />}
                  {tab === "community" && <CommunityScreen />}
                  {tab === "bookings"  && <BookingsScreen  onSelect={setSheet} />}
                  {tab === "profile"   && <ProfileScreen />}
                  {sheet && <BookingSheet ins={sheet} onClose={() => setSheet(null)} />}
                </div>
                <TabBar tab={tab} setTab={setTab} />
              </div>
            </div>
          </div>
        </div>

        {/* Sheen */}
        <div className="absolute inset-x-0 top-0 rounded-t-[54px] pointer-events-none"
          style={{ height:120, background:"linear-gradient(to bottom,rgba(255,255,255,0.3),transparent)" }} />

        <p className="text-center mt-5 text-[11px]" style={{ ...MONO, color:"rgba(212,88,128,0.6)" }}>
          Flowe · iPhone 15 Pro · 393×852
        </p>
      </div>
    </div>
  );
}
