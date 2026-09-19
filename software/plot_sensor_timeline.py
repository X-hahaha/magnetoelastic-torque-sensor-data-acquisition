#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""sensor_timeline 交互式曲线工具

输入任意一份 frame_XXXXXX_sensor_timeline.csv，输出一个自包含的交互式 HTML
（数据内嵌，无 CDN、无网络依赖，双击即可打开）。

用法
----
    python plot_sensor_timeline.py <csv路径> [选项]

选项
----
    -o, --out PATH     输出 HTML 路径。默认写在 csv 同级目录下，
                       命名 <csv名去掉 _sensor_timeline.csv>_interactive.html
    -c, --col COL      初始列，默认 l2_um
    --mask-mode MODE   初始数据口径：bit / eq / all，默认 bit。
                       对 L2 来说 bit 等价于 update_mask & 2 != 0
    --rpm RPM          轴转速；提供后显示每转参考线和悬停转角
    --serve            生成后起一个本地 HTTP 服务并打开浏览器（默认直接打开文件）
    --port N           本地服务端口，默认 8765
    --no-open          只生成文件，不自动打开

页面功能
--------
    · 通道切换（L1~L5、temp）——全为 -1 的通道自动隐藏
    · 掩码过滤：全部 / ==bit / &bit（默认 &bit；位号按通道自动推导）
      “含合并上报”一律用 &，它比 == 多出 mask=6/10/14 这类多通道联合上报的记录
    · 连线：阶梯（零阶保持的真实语义）/ 折线
    · 缺测：-1 读数高亮成区间，可选“断线”或“跨接”，并列出每段的起止与宽度
    · 滚轮以光标为锚点缩放、拖动平移、悬停十字线读数（时间 / 数值 / update_mask 二进制）
    · 底部缩略全览，拖动平移视窗
    · 可选轴转速参考线；悬停同时显示累计圈数和转角
    · 自动给出缺测段的节拍：段起点间隔是否等距 / 是否交替（两倍频）

依赖：仅标准库（matplotlib 不需要）
"""
import argparse
import csv
import json
import os
import sys

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8")

# 列名 -> (显示名, update_mask 位序号)
CHANNELS = [
    ("l1_um", "L1", 0),
    ("l2_um", "L2", 1),
    ("l3_um", "L3", 2),
    ("l4_um", "L4", 3),
    ("l5_um", "L5", 4),
    ("temp_x10", "温度×10", 5),
]
INVALID_BELOW = 0          # 本格式里 -1 表示无效 / 未安装


def load(path):
    with open(path, newline="", encoding="utf-8-sig") as fh:
        rows = list(csv.DictReader(fh))
    if not rows:
        raise SystemExit("CSV 里没有数据行：%s" % path)
    have = set(rows[0].keys())
    t = [int(r["timestamp_us"]) / 1000.0 for r in rows]        # ms
    msk = [int(r["update_mask"]) for r in rows]
    cols, meta = {}, []
    for name, disp, bit in CHANNELS:
        if name not in have:
            continue
        v = []
        ok = 0
        for r in rows:
            x = int(r[name])
            if x < INVALID_BELOW:
                v.append(None)
            else:
                v.append(x)
                ok += 1
        if ok == 0:            # 整列无效 = 未安装，不展示
            continue
        cols[name] = v
        meta.append({"key": name, "disp": disp, "bit": bit, "valid": ok})
    if not cols:
        raise SystemExit("没有任何通道含有效数据")
    return {"t": t, "mask": msk, "cols": cols, "meta": meta, "n": len(rows)}


HTML = r"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<title>__TITLE__</title>
<style>
  :root{--bg:#fff;--panel:#f7f8fa;--line:#e3e6ea;--text:#1f2328;--muted:#6b7280;--acc:#0b4ea2;}
  *{box-sizing:border-box}
  body{margin:0;background:var(--bg);color:var(--text);
       font:14px/1.5 "Segoe UI","Microsoft YaHei",system-ui,sans-serif}
  .wrap{max-width:1320px;margin:0 auto;padding:20px 22px 34px}
  h1{font-size:18px;margin:0 0 3px;font-weight:650;word-break:break-all}
  .sub{color:var(--muted);font-size:12.5px;margin-bottom:12px}
  .chips{display:flex;flex-wrap:wrap;gap:8px;margin-bottom:12px}
  .chip{background:var(--panel);border:1px solid var(--line);border-radius:6px;padding:5px 10px;
        font-size:12px;color:var(--muted)}
  .chip b{color:var(--text);font-weight:600;font-variant-numeric:tabular-nums}
  .bar{display:flex;flex-wrap:wrap;gap:14px;align-items:center;margin-bottom:10px}
  .grp{display:flex;align-items:center;gap:6px;flex-wrap:wrap}
  .gl{color:var(--muted);font-size:12px}
  button{background:var(--panel);border:1px solid var(--line);border-radius:6px;padding:5px 11px;
         font-size:12.5px;color:var(--text);cursor:pointer;font-family:inherit;transition:.12s}
  button:hover{border-color:#b9c0c9;background:#eef1f4}
  button.on{background:#e7f0fe;border-color:#9cc2fb;color:var(--acc);font-weight:600}
  .hint{color:var(--muted);font-size:12px;margin-left:auto}
  .stage{position:relative}
  canvas{display:block;width:100%;border:1px solid var(--line);border-radius:10px;background:#fff}
  #main{cursor:crosshair}
  #mini{height:68px;margin-top:9px;cursor:ew-resize}
  .cap{color:var(--muted);font-size:11.5px;margin-top:5px}
  .tip{position:absolute;pointer-events:none;background:rgba(255,255,255,.97);border:1px solid var(--line);
       border-radius:8px;padding:8px 11px;font-size:12px;box-shadow:0 6px 20px rgba(20,30,50,.10);
       white-space:nowrap;opacity:0;transition:opacity .1s;font-variant-numeric:tabular-nums;z-index:5}
  .tip .k{color:var(--muted);margin-right:6px}
  .tip .v{font-weight:600}
  .panel{margin-top:14px;border:1px solid var(--line);border-radius:10px;overflow:hidden}
  .panel h2{margin:0;padding:8px 12px;font-size:13px;background:var(--panel);
            border-bottom:1px solid var(--line);font-weight:600}
  .panel .body{padding:10px 12px;font-size:12.5px;color:var(--text)}
  table{border-collapse:collapse;font-size:12px;width:100%;font-variant-numeric:tabular-nums}
  th,td{text-align:right;padding:3px 8px;border-bottom:1px solid #f0f2f5}
  th:first-child,td:first-child{text-align:left}
  th{color:var(--muted);font-weight:500}
  .warn{color:#b54708}
  .bad{color:#d1242f}
  .seg{line-height:1.9}
  code{background:var(--panel);padding:1px 5px;border-radius:4px;font-size:12px}
</style>
</head>
<body>
<div class="wrap">
  <h1 id="ttl"></h1>
  <div class="sub" id="sub"></div>
  <div class="chips" id="chips"></div>

  <div class="bar">
    <div class="grp"><span class="gl">通道</span><span id="chGrp"></span></div>
    <div class="grp"><span class="gl">掩码</span>
      <button data-mask="all">全部</button>
      <button data-mask="eq">== bit</button>
      <button data-mask="bit" class="on">&amp; bit</button>
    </div>
    <div class="grp"><span class="gl">连线</span>
      <button data-line="stair" class="on">阶梯</button>
      <button data-line="poly">折线</button>
    </div>
    <div class="grp"><span class="gl">缺测</span>
      <button data-gap="break" class="on">断线</button>
      <button data-gap="join">跨接</button>
    </div>
    <div class="grp" id="revGrp"><span class="gl">转速</span><button id="bRev" class="on"></button></div>
    <div class="grp"><button id="bRst">重置视图</button></div>
    <span class="hint">滚轮缩放 · 拖动平移 · 悬停读数</span>
  </div>

  <div class="stage">
    <canvas id="main"></canvas>
    <div class="tip" id="tip"></div>
  </div>
  <canvas id="mini"></canvas>
  <div class="cap">缩略全览：拖动可平移视窗</div>

  <div class="panel">
    <h2>缺测段（读数 = -1）</h2>
    <div class="body">
      <div id="segs" class="seg"></div>
      <div id="beat" style="margin-top:8px"></div>
    </div>
  </div>
</div>

<script>
const D = __DATA__;
const MC = {l:70, r:18, t:16, b:34};
const CC = {l:0,  r:0,  t:6,  b:12};
const main = document.getElementById('main'), mini = document.getElementById('mini');
const mctx = main.getContext('2d'), mictx = mini.getContext('2d');
const tip = document.getElementById('tip');

const TS=[0.001,0.002,0.005,0.01,0.02,0.05,0.1,0.2,0.5,1,2,5,10,20,25,50,100,200,250,500,1000];
const YS=[0.05,0.1,0.2,0.25,0.5,1,2,5,10,20,25,50,100,200,250,500,1000,2000,5000];
function niceStep(raw,list){ for(const s of list) if(s>=raw) return s; return list[list.length-1]; }

let col = D.initCol;
let bit = 1<<metaOf(col).bit, bitDisp = metaOf(col).disp;
let maskMode=D.initMask, lineMode='stair', gapMode='break';
let revMode=D.rpm>0;
let view={x0:0,x1:1}, size, csize, sel=[], badRuns=[], VIS={lo:0,hi:0};

function metaOf(k){ return D.meta.find(m=>m.key===k); }

document.getElementById('ttl').textContent = D.title;
document.getElementById('sub').innerHTML =
  D.sub + '　·　共 ' + D.n + ' 条记录　·　' +
  '时间轴单位 ms（timestamp_us 的末值 ' + D.tMax.toFixed(3) + ' ms）';

function fmtNum(x){
  if(!isFinite(x)) return '—';
  const s = Math.abs(x) >= 100 ? x.toFixed(1) : x.toFixed(3);
  return s.replace(/\.?0+$/,'');
}
function buildChannels(){
  const g = document.getElementById('chGrp');
  g.innerHTML = '';                       // 必须先清空，否则每次点击都会再追加一排按钮
  D.meta.forEach(m=>{
    const b=document.createElement('button');
    b.textContent = m.disp; b.dataset.col = m.key;
    b.classList.toggle('on', m.key===col);
    b.onclick=()=>{ col=m.key; buildChannels(); refresh(); };
    g.appendChild(b);
  });
}
function buildBadRuns(){
  const idx=[]; sel.forEach((r,i)=>{ if(r.v===null) idx.push(i); });
  badRuns=[];
  if(!idx.length) return;
  let s=idx[0],p=idx[0];
  for(const i of idx.slice(1)){ if(i===p+1) p=i; else {badRuns.push([s,p]); s=p=i;} }
  badRuns.push([s,p]);
}
function pick(){
  const raw = D.t.map((t,i)=>({t, v:D.cols[col][i], m:D.mask[i]}));
  if(maskMode==='eq')  return raw.filter(r=>r.m===bit);
  if(maskMode==='bit') return raw.filter(r=>r.m & bit);
  return raw;
}
function refresh(){
  const m = metaOf(col); bit = 1<<m.bit; bitDisp = m.disp;
  document.getElementById('sub').innerHTML =
    '当前通道 <b>'+m.disp+'</b>（'+col+'，对应 update_mask 的 bit'+m.bit+'='+bit+'）　·　'+D.sub;
  document.querySelectorAll('[data-mask]').forEach(x=>{
    if(x.dataset.mask==='eq') x.textContent='== '+bit;
    if(x.dataset.mask==='bit') x.textContent='& '+bit;
  });
  sel = pick();
  if(!sel.length){
    document.getElementById('chips').innerHTML='<span class="chip"><b>当前掩码口径没有记录</b></span>';
    document.getElementById('segs').textContent='请切换“全部”或其他掩码口径。';
    document.getElementById('beat').textContent='';
    render();
    return;
  }
  view.x0=sel[0].t; view.x1=sel[sel.length-1].t;
  buildBadRuns();
  const v=sel.filter(r=>r.v!==null), vals=v.map(r=>r.v);
  const chg=[];
  for(let i=1;i<v.length;i++) if(v[i].v!==v[i-1].v) chg.push(i);
  const iv=[]; for(let i=1;i<chg.length;i++) iv.push(v[chg[i]].t-v[chg[i-1]].t);
  iv.sort((a,b)=>a-b);
  const med = iv.length? iv[Math.floor(iv.length/2)] : null;
  const mean = vals.length ? vals.reduce((a,b)=>a+b,0)/vals.length : NaN;
  const sd = vals.length ? Math.sqrt(vals.reduce((a,b)=>a+(b-mean)**2,0)/Math.max(1,vals.length-1)) : NaN;
  let same=0, pairs=0;
  for(let i=1;i<sel.length;i++){
    if(sel[i-1].v===null || sel[i].v===null) continue;
    pairs++;
    if(sel[i-1].v===sel[i].v) same++;
  }
  const plateaus=[];
  let ps=null, pp=null;
  for(const r of sel){
    if(r.v===null){ if(ps!==null) plateaus.push(pp.t-ps.t); ps=pp=null; continue; }
    if(ps===null){ ps=pp=r; continue; }
    if(r.v===pp.v){ pp=r; continue; }
    plateaus.push(pp.t-ps.t); ps=pp=r;
  }
  if(ps!==null) plateaus.push(pp.t-ps.t);
  const pSorted=plateaus.slice().sort((a,b)=>a-b);
  const pMed=pSorted.length?pSorted[Math.floor(pSorted.length/2)]:null;
  const pMax=pSorted.length?pSorted[pSorted.length-1]:null;
  const f=(x,n)=> (x===null?'—':x.toFixed(n));
  document.getElementById('chips').innerHTML=[
    ['选中记录', sel.length+' 条'],
    ['有效点', v.length+' 条'],
    ['无效 -1', '<span class="bad">'+(sel.length-v.length)+' 条 / '+badRuns.length+' 段</span>'],
    ['值域', vals.length?Math.min(...vals)+' – '+Math.max(...vals):'—'],
    ['跨度', vals.length?(Math.max(...vals)-Math.min(...vals)):'—'],
    ['均值', fmtNum(mean)],
    ['标准差', fmtNum(sd)],
    ['有效相邻重复', pairs?(100*same/pairs).toFixed(1)+'%':'—'],
    ['平台中位 / 最长', pMed===null?'—':pMed.toFixed(3)+' / '+pMax.toFixed(3)+' ms'],
    ['变化沿', chg.length+' 个'],
    ['变化间隔中位', med===null?'—':f(med,3)+' ms'],
    ...(D.rpm>0?[['转速',fmtNum(D.rpm)+' rpm'],['覆盖圈数',fmtNum(D.tMax*D.rpm/60000)]]:[]),
  ].map(([k,x])=>`<span class="chip">${k} <b>${x}</b></span>`).join('');
  renderSegs();
  render();
}
function renderSegs(){
  const el=document.getElementById('segs'), bt=document.getElementById('beat');
  if(!badRuns.length){ el.innerHTML='<span style="color:#6b7280">本通道在该掩码口径下没有无效读数。</span>'; bt.innerHTML=''; return; }
  let h='<table><tr><th>#</th><th>起 (ms)</th><th>止 (ms)</th><th>宽度 (ms)</th><th>条数</th></tr>';
  badRuns.forEach(([a,b],i)=>{
    h += '<tr><td>'+(i+1)+'</td><td>'+sel[a].t.toFixed(3)+'</td><td>'+sel[b].t.toFixed(3)+
         '</td><td>'+(sel[b].t-sel[a].t).toFixed(3)+'</td><td>'+(b-a+1)+'</td></tr>';
  });
  h+='</table>';
  const span = sel[sel.length-1].t - sel[0].t;
  const tot = badRuns.reduce((s,[a,b])=>s+(sel[b].t-sel[a].t),0);
  el.innerHTML = h + '<div style="margin-top:6px;color:#6b7280">缺测总时长 '+tot.toFixed(3)+
                 ' ms，占整段 '+(span?100*tot/span:0).toFixed(1)+'%</div>';
  // 节拍判定：先看是否交替（两倍频），再看是否接近等距，最后才说不规律
  if(badRuns.length>=3){
    const st=badRuns.map(([a])=>sel[a].t);
    const wd=badRuns.map(([a,b])=>sel[b].t-sel[a].t);
    const d=[]; for(let i=1;i<st.length;i++) d.push(st[i]-st[i-1]);
    const mu=d.reduce((a,b)=>a+b,0)/d.length;
    const sd=Math.sqrt(d.reduce((a,b)=>a+(b-mu)**2,0)/Math.max(1,d.length-1));
    const d0=d.filter((_,i)=>i%2===0), d1=d.filter((_,i)=>i%2===1);
    const m0=d0.reduce((a,b)=>a+b,0)/d0.length;
    const m1=d1.length? d1.reduce((a,b)=>a+b,0)/d1.length : NaN;
    const rel = d1.length? Math.abs(m0-m1)/((m0+m1)/2) : 0;
    const relsd = mu? sd/mu : 1;
    let verdict;
    if(d1.length && rel > 0.05)
      verdict='<b>间隔交替</b>：第 1/3/5… 个 '+m0.toFixed(2)+' ms，第 2/4/6… 个 '+m1.toFixed(2)+
              ' ms（相差 '+(100*rel).toFixed(1)+'%）→ 不是随机丢失。一对和 '+(m0+m1).toFixed(2)+
              ' ms，且这个和在各对之间高度稳定，说明丢弃与一个约 '+(m0+m1).toFixed(2)+
              ' ms 的慢节拍锁相；A/B 两个值不等，说明该节拍与采样/转动之间还有相位滑动，'+
              '<b>不能只报一个"周期"</b>';
    else if(relsd < 0.03) verdict='<b>严格等距</b> → 周期性丢失，不是随机读失败';
    else if(relsd < 0.08) verdict='<b>接近等距</b>（stdev 占均值 '+(100*relsd).toFixed(1)+
              '%），极差 '+(Math.max(...d)-Math.min(...d)).toFixed(2)+' ms → 仍是周期性丢失';
    else verdict='<span class="warn">间隔不规律</span>（stdev 占均值 '+(100*relsd).toFixed(1)+'%）';
    const wmin=Math.min(...wd), wmax=Math.max(...wd);
    const walt = (()=>{ if(badRuns.length<4) return false;
      const w0=wd.filter((_,i)=>i%2===0), w1=wd.filter((_,i)=>i%2===1);
      const a=w0.reduce((x,y)=>x+y,0)/w0.length, b=w1.reduce((x,y)=>x+y,0)/w1.length;
      return Math.abs(a-b)/((a+b)/2) > 0.15; })();
    bt.innerHTML='段起点间隔：'+d.map(x=>x.toFixed(2)).join(' / ')+' ms<br>'+
                 '均值 '+mu.toFixed(3)+' ms，stdev '+sd.toFixed(3)+
                 '，极差 '+(Math.max(...d)-Math.min(...d)).toFixed(3)+'（'+d.length+' 个间隔）<br>'+
                 '段宽 '+wmin.toFixed(2)+' ~ '+wmax.toFixed(2)+' ms'+(walt?'（<b>长短交替</b>）':'')+
                 '<br>判定：'+verdict;
  } else bt.innerHTML='';
}

function yRange(){
  let lo=Infinity,hi=-Infinity;
  for(const r of sel) if(r.v!==null && r.t>=view.x0 && r.t<=view.x1){ if(r.v<lo)lo=r.v; if(r.v>hi)hi=r.v; }
  if(lo===Infinity){ lo=0; hi=1; }
  VIS={lo,hi};
  const pad=Math.max((hi-lo)*0.12, (hi-lo)===0?Math.max(1,Math.abs(lo)*0.01):0);
  let a=lo-pad,b=hi+pad;
  const step=niceStep((b-a)/6, YS);
  a=Math.floor(a/step)*step; b=Math.ceil(b/step)*step;
  return [a,b,step];
}
function decOf(step){ const s=String(step); return s.includes('.')? s.split('.')[1].length:0; }

function drawMain(){
  const {w,h}=size;
  const [yLo,yHi,ystep]=yRange();
  const X=t=>MC.l+(t-view.x0)/(view.x1-view.x0||1)*(w-MC.l-MC.r);
  const Y=v=>MC.t+(yHi-v)/(yHi-yLo||1)*(h-MC.t-MC.b);
  const PW=w-MC.l-MC.r, PH=h-MC.t-MC.b;
  mctx.clearRect(0,0,w,h);
  mctx.font='11px "Segoe UI",sans-serif';
  const ydec=decOf(ystep);
  mctx.textAlign='right'; mctx.textBaseline='middle';
  for(let v=Math.ceil(yLo/ystep)*ystep; v<=yHi+1e-9; v+=ystep){
    const y=Y(v);
    mctx.strokeStyle='#eceff3'; mctx.lineWidth=1;
    mctx.beginPath(); mctx.moveTo(MC.l,y); mctx.lineTo(w-MC.r,y); mctx.stroke();
    mctx.fillStyle='#6b7280'; mctx.fillText(v.toFixed(ydec), MC.l-8, y);
  }
  mctx.save(); mctx.translate(14,h/2); mctx.rotate(-Math.PI/2);
  mctx.textAlign='center'; mctx.fillStyle='#6b7280'; mctx.font='11.5px "Segoe UI",sans-serif';
  mctx.fillText(col, 0, 0); mctx.restore();

  const every=niceStep((view.x1-view.x0)/12, TS);
  const xdec=decOf(every);
  mctx.textAlign='center'; mctx.textBaseline='top';
  for(let k=Math.ceil(view.x0/every); k<=Math.floor(view.x1/every); k++){
    const x=X(k*every);
    mctx.strokeStyle='#f4f6f9'; mctx.lineWidth=1;
    mctx.beginPath(); mctx.moveTo(x,MC.t); mctx.lineTo(x,h-MC.b); mctx.stroke();
    mctx.fillStyle='#6b7280'; mctx.fillText((k*every).toFixed(xdec), x, h-MC.b+8);
  }
  mctx.strokeStyle='#d8dde4'; mctx.lineWidth=1;
  mctx.beginPath(); mctx.moveTo(MC.l,MC.t); mctx.lineTo(MC.l,h-MC.b); mctx.lineTo(w-MC.r,h-MC.b); mctx.stroke();

  if(revMode && D.rpm>0){
    const period=60000/D.rpm;
    const n0=Math.ceil(view.x0/period), n1=Math.floor(view.x1/period);
    mctx.save();
    mctx.setLineDash([5,4]); mctx.lineWidth=1; mctx.strokeStyle='rgba(181,91,0,.45)';
    mctx.textAlign='left'; mctx.textBaseline='top'; mctx.fillStyle='#8a4b08';
    for(let n=n0;n<=n1;n++){
      const x=X(n*period);
      mctx.beginPath(); mctx.moveTo(x,MC.t); mctx.lineTo(x,h-MC.b); mctx.stroke();
      if(x>=MC.l+3 && x<=w-MC.r-38) mctx.fillText('第 '+n+' 圈',x+4,MC.t+4);
    }
    mctx.restore();
  }

  mctx.save(); mctx.beginPath(); mctx.rect(MC.l,MC.t,PW,PH); mctx.clip();
  for(const [a,b] of badRuns){
    const x1=X(sel[a].t), x2=X(sel[b].t);
    if(x2<MC.l||x1>w-MC.r) continue;
    mctx.fillStyle='rgba(209,36,47,.10)';
    mctx.fillRect(x1,MC.t,Math.max(1.2,x2-x1),PH);
    mctx.fillStyle='rgba(209,36,47,.55)';
    mctx.fillRect(x1,MC.t,Math.max(1.2,x2-x1),2);
  }
  mctx.strokeStyle='#1f6feb'; mctx.lineWidth=1.3; mctx.lineJoin='round'; mctx.lineCap='round';
  mctx.beginPath();
  let started=false, prevY=0;
  for(const r of sel){
    if(r.v===null){ if(gapMode==='break') started=false; continue; }
    const x=X(r.t), y=Y(r.v);
    if(!started){ mctx.moveTo(x,y); }
    else if(lineMode==='stair'){ mctx.lineTo(x,prevY); mctx.lineTo(x,y); }
    else mctx.lineTo(x,y);
    started=true; prevY=y;
  }
  mctx.stroke();
  mctx.fillStyle='#d1242f';
  for(const [a,b] of badRuns){
    const x1=X(sel[a].t), x2=X(sel[b].t);
    if(x2<MC.l||x1>w-MC.r) continue;
    const n=b-a+1, y=h-MC.b-4, stride=Math.max(1,Math.ceil(n/12));
    for(let i=a;i<=b;i+=stride){
      const x=X(sel[i].t);
      mctx.beginPath(); mctx.moveTo(x,y-5); mctx.lineTo(x+4,y+1.6); mctx.lineTo(x-4,y+1.6);
      mctx.closePath(); mctx.fill();
    }
  }
  mctx.restore();

  let n=0;
  for(const r of sel) if(r.v!==null && r.t>=view.x0 && r.t<=view.x1) n++;
  mctx.font='11.5px "Segoe UI",sans-serif';
  mctx.textAlign='right'; mctx.textBaseline='top'; mctx.fillStyle='#57606a';
  mctx.fillText('可见 '+n+' 点　min '+VIS.lo+'　max '+VIS.hi, w-MC.r-6, MC.t+2);
}
function drawMini(){
  const {w,h}=csize;
  const t0=sel[0].t, t1=sel[sel.length-1].t;
  const MX=t=>CC.l+(t-t0)/(t1-t0||1)*(w-CC.l-CC.r);
  let lo=Infinity,hi=-Infinity;
  for(const r of sel) if(r.v!==null){ if(r.v<lo)lo=r.v; if(r.v>hi)hi=r.v; }
  if(lo===Infinity){lo=0;hi=1;}
  const Y=v=>CC.t+(hi-v)/((hi-lo)||1)*(h-CC.t-CC.b);
  mictx.clearRect(0,0,w,h);
  mictx.strokeStyle='#9dc0f5'; mictx.lineWidth=1; mictx.beginPath();
  let started=false, prevY=0;
  for(const r of sel){
    if(r.v===null){ if(gapMode==='break') started=false; continue; }
    const x=MX(r.t), y=Y(r.v);
    if(!started) mictx.moveTo(x,y);
    else if(lineMode==='stair'){ mictx.lineTo(x,prevY); mictx.lineTo(x,y); }
    else mictx.lineTo(x,y);
    started=true; prevY=y;
  }
  mictx.stroke();
  const a=MX(view.x0), b=MX(view.x1);
  mictx.fillStyle='rgba(31,35,40,.10)';
  if(a>CC.l) mictx.fillRect(CC.l,0,a-CC.l,h);
  if(b<w-CC.r) mictx.fillRect(b,0,w-CC.r-b,h);
  mictx.strokeStyle='#1f2328'; mictx.lineWidth=1;
  mictx.strokeRect(a+.5,.5,Math.max(1,b-a-1),h-1);
}
function render(){
  // size 由 resize() 建立、sel 由 refresh() 建立。两者任一没就绪就什么都不画，
  // 否则会在"先 refresh 后 resize"的初始化顺序下抛异常，画布留白。
  if(!size || !sel || !sel.length) return;
  drawMain(); drawMini();
}

function resize(){
  const dpr=window.devicePixelRatio||1;
  const w=main.parentElement.clientWidth||900;
  const h=Math.max(320,Math.min(540,Math.round(w*0.42)));
  size={w,h};
  main.style.height=h+'px'; main.width=Math.round(w*dpr); main.height=Math.round(h*dpr);
  mctx.setTransform(dpr,0,0,dpr,0,0);
  csize={w,h:68};
  mini.style.height='68px'; mini.width=Math.round(w*dpr); mini.height=Math.round(68*dpr);
  mictx.setTransform(dpr,0,0,dpr,0,0);
  render();
}
function toT(clientX){
  const r=main.getBoundingClientRect();
  return view.x0+((clientX-r.left-MC.l)/(r.width-MC.l-MC.r))*(view.x1-view.x0);
}
const TMIN=()=>sel[0].t, TMAX=()=>sel[sel.length-1].t;

let drag=null;
main.addEventListener('wheel',e=>{
  e.preventDefault();
  const t=toT(e.clientX), k=e.deltaY>0?1.18:1/1.18;
  let a=Math.max(TMIN(),t-(t-view.x0)*k), b=Math.min(TMAX(),t+(view.x1-t)*k);
  if(b-a < (TMAX()-TMIN())*0.0015) return;
  view.x0=a; view.x1=b; render();
},{passive:false});
main.addEventListener('mousedown',e=>{ drag={x:e.clientX,x0:view.x0,x1:view.x1}; main.style.cursor='grabbing'; });
window.addEventListener('mouseup',()=>{ drag=null; main.style.cursor='crosshair'; });
window.addEventListener('mousemove',e=>{
  const r=main.getBoundingClientRect();
  if(drag){
    const per=(view.x1-view.x0)/(r.width-MC.l-MC.r);
    let a=drag.x0-(e.clientX-drag.x)*per, b=drag.x1-(e.clientX-drag.x)*per;
    if(a<TMIN()){ b+=TMIN()-a; a=TMIN(); }
    if(b>TMAX()){ a-=b-TMAX(); b=TMAX(); }
    view.x0=a; view.x1=b; render(); return;
  }
  if(e.clientX<r.left||e.clientX>r.right||e.clientY<r.top||e.clientY>r.bottom){ tip.style.opacity=0; return; }
  const t=toT(e.clientX);
  let best=null,bd=1e9;
  for(const rr of sel){ const d=Math.abs(rr.t-t); if(d<bd){bd=d;best=rr;} }
  if(!best){ tip.style.opacity=0; return; }
  tip.innerHTML='<div><span class="k">时间</span><span class="v">'+best.t.toFixed(3)+' ms</span></div>'+ 
    '<div><span class="k">'+col+'</span><span class="v" style="color:'+(best.v===null?'#d1242f':'#1f2328')+
    '">'+(best.v===null?'-1（无效）':best.v)+'</span></div>'+ 
    '<div><span class="k">update_mask</span><span class="v">'+best.m+' (0b'+
    best.m.toString(2).padStart(6,'0')+')</span></div>'+ 
    (D.rpm>0?'<div><span class="k">轴位置</span><span class="v">第 '+
      (best.t*D.rpm/60000).toFixed(4)+' 圈，'+
      ((best.t*D.rpm/60000%1)*360).toFixed(1)+'°</span></div>':'');
  tip.style.opacity=1;
  tip.style.left=Math.min(r.width-230,Math.max(0,e.clientX-r.left+14))+'px';
  tip.style.top=Math.max(0,e.clientY-r.top-16)+'px';
  render();
  const x=MC.l+(best.t-view.x0)/(view.x1-view.x0||1)*(r.width-MC.l-MC.r);
  mctx.save(); mctx.strokeStyle='#9aa2ad'; mctx.lineWidth=1; mctx.setLineDash([3,3]);
  mctx.beginPath(); mctx.moveTo(x,MC.t); mctx.lineTo(x,r.height-MC.b); mctx.stroke(); mctx.restore();
});
let mdrag=false;
mini.addEventListener('mousedown',e=>{ mdrag=true; miniMove(e); });
window.addEventListener('mouseup',()=>mdrag=false);
mini.addEventListener('mousemove',e=>{ if(mdrag) miniMove(e); });
function miniMove(e){
  const r=mini.getBoundingClientRect();
  const f=Math.max(0,Math.min(1,(e.clientX-r.left-CC.l)/(r.width-CC.l-CC.r)));
  const t=TMIN()+f*(TMAX()-TMIN()), half=(view.x1-view.x0)/2;
  view.x0=Math.max(TMIN(),t-half); view.x1=Math.min(TMAX(),t+half); render();
}
document.querySelectorAll('[data-mask]').forEach(b=>b.onclick=()=>{
  maskMode=b.dataset.mask;
  document.querySelectorAll('[data-mask]').forEach(x=>x.classList.toggle('on',x===b));
  refresh();
});
document.querySelectorAll('[data-line]').forEach(b=>b.onclick=()=>{
  lineMode=b.dataset.line;
  document.querySelectorAll('[data-line]').forEach(x=>x.classList.toggle('on',x===b));
  refresh();
});
document.querySelectorAll('[data-gap]').forEach(b=>b.onclick=()=>{
  gapMode=b.dataset.gap;
  document.querySelectorAll('[data-gap]').forEach(x=>x.classList.toggle('on',x===b));
  refresh();
});
document.getElementById('bRst').onclick=()=>{ view.x0=sel[0].t; view.x1=sel[sel.length-1].t; render(); };
const revGrp=document.getElementById('revGrp'), bRev=document.getElementById('bRev');
revGrp.hidden=!(D.rpm>0);
if(D.rpm>0){
  bRev.textContent='转圈线 '+fmtNum(D.rpm)+' rpm';
  bRev.onclick=()=>{ revMode=!revMode; bRev.classList.toggle('on',revMode); render(); };
}
document.querySelectorAll('[data-mask]').forEach(x=>x.classList.toggle('on',x.dataset.mask===maskMode));
window.addEventListener('resize',resize);
// 顺序要紧：resize() 先建立画布尺寸，refresh() 才算数据并画。
// 反过来（先 refresh）会让 render() 在 size 尚未定义时抛异常，画布一片空白，
// 而且只有等到窗口 resize 事件才偶然恢复 —— 这个 bug 现在由 render() 的守卫兜住。
resize();
buildChannels();
refresh();
</script>
</body>
</html>
"""


def build_html(data, title, sub, init_col, init_mask, rpm):
    js = dict(data)
    js["title"] = title
    js["sub"] = sub
    js["initCol"] = init_col
    js["initMask"] = init_mask
    js["rpm"] = rpm or 0
    js["tMax"] = data["t"][-1]
    out = HTML.replace("__DATA__", json.dumps(js, separators=(",", ":")))
    out = out.replace("__TITLE__", title)
    return out


def main():
    ap = argparse.ArgumentParser(
        description="sensor_timeline CSV -> 自包含交互式曲线 HTML",
        formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    ap.add_argument("csv")
    ap.add_argument("-o", "--out", default=None)
    ap.add_argument("-c", "--col", default="l2_um")
    ap.add_argument("--mask-mode", choices=("bit", "eq", "all"), default="bit",
                    help="初始掩码口径，默认 bit（通道位非零）")
    ap.add_argument("--rpm", type=float, default=None,
                    help="轴转速；提供后显示每转参考线和悬停转角")
    ap.add_argument("--serve", action="store_true")
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--no-open", action="store_true", dest="no_open")
    a = ap.parse_args()

    if not os.path.isfile(a.csv):
        raise SystemExit("找不到文件：%s" % a.csv)

    data = load(a.csv)
    avail = [m["key"] for m in data["meta"]]
    if a.col not in data["cols"]:
        fallback = "l2_um" if "l2_um" in data["cols"] else avail[0]
        print("提示：%s 在本文件里没有有效数据，改用 %s（可选：%s）"
              % (a.col, fallback, ", ".join(avail)), file=sys.stderr)
        a.col = fallback

    base = os.path.basename(a.csv).replace("_sensor_timeline.csv", "").replace(".csv", "")
    out = a.out or os.path.join(os.path.dirname(os.path.abspath(a.csv)),
                                "%s_interactive.html" % base)
    out = os.path.abspath(out)
    odir = os.path.dirname(out)
    if odir and not os.path.isdir(odir):
        os.makedirs(odir, exist_ok=True)      # 否则 -o 指到新目录会直接抛 FileNotFoundError
    title = "%s  传感器时间线交互曲线" % base
    sub = os.path.basename(a.csv)
    html = build_html(data, title, sub, a.col, a.mask_mode, a.rpm)
    with open(out, "w", encoding="utf-8") as f:
        f.write(html)

    print("输入 : %s" % a.csv)
    print("记录 : %d 条，%.3f – %.3f ms" % (data["n"], data["t"][0], data["t"][-1]))
    for m in data["meta"]:
        print("        %-4s %-9s bit%-2d 有效 %4d" % (m["disp"], m["key"], m["bit"], m["valid"]))
    print("输出 : %s  (%.1f KB)" % (out, os.path.getsize(out) / 1024.0))

    if a.serve:
        import functools
        import http.server
        import socketserver
        import threading
        import webbrowser
        d = os.path.dirname(os.path.abspath(out))
        h = functools.partial(http.server.SimpleHTTPRequestHandler, directory=d)
        with socketserver.TCPServer(("127.0.0.1", a.port), h) as httpd:
            url = "http://127.0.0.1:%d/%s" % (a.port, os.path.basename(out))
            print("服务 : %s   (Ctrl+C 结束)" % url)
            if not a.no_open:
                threading.Timer(0.6, lambda: webbrowser.open(url)).start()
            try:
                httpd.serve_forever()
            except KeyboardInterrupt:
                print("\n已停止")
    elif not a.no_open:
        import webbrowser
        webbrowser.open("file:///" + os.path.abspath(out).replace("\\", "/"))


if __name__ == "__main__":
    main()
