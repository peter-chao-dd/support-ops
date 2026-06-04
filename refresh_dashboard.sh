#!/bin/bash
# refresh_dashboard.sh — Re-queries Snowflake, rebuilds index.html, pushes to GitHub
# Runs weekly via launchd. Logs to ~/Library/Logs/dashboard_refresh.log

set -euo pipefail

LOG="$HOME/Library/Logs/dashboard_refresh.log"
PROJECT="$HOME/Desktop/peter-brief"
CSV="/tmp/llm_judge_agg_refresh.csv"
JSON="/tmp/llm_judge_data_refresh.json"
BUILDER="/tmp/build_dashboard.py"

echo "" >> "$LOG"
echo "======================================" >> "$LOG"
echo "$(date): Starting dashboard refresh" >> "$LOG"

# ── 1. Query Snowflake ──────────────────────────────────────────────────────
echo "$(date): Querying Snowflake..." >> "$LOG"

SNOWFLAKE_CONNECTIONS_DEFAULT_ACCOUNT="doordash-doordash" \
SNOWFLAKE_CONNECTIONS_DEFAULT_USER="PETER.CHAO" \
SNOWFLAKE_CONNECTIONS_DEFAULT_WAREHOUSE="ADHOC" \
  snow sql -q "ALTER SESSION SET QUERY_TAG = 'dashboard-refresh';
SELECT
  SAMPLE_DATE,
  VENDOR,
  DASHER_DELIVERY_STATUS,
  OUTCOME,
  COUNT(*) AS call_count
FROM PRODDB.DAVIDBORRELLI.VOICE_SUPPORT_LLM_JUDGE_RESULTS
WHERE OUTCOME IS NOT NULL
GROUP BY 1,2,3,4
ORDER BY 1,2,3,4;" --format CSV | tail -n +4 > "$CSV"

ROW_COUNT=$(wc -l < "$CSV" | tr -d ' ')
echo "$(date): Got $ROW_COUNT rows from Snowflake" >> "$LOG"

if [ "$ROW_COUNT" -eq 0 ]; then
  echo "$(date): ERROR — No data returned from Snowflake. Aborting." >> "$LOG"
  exit 1
fi

# ── 2. Convert CSV → JSON ───────────────────────────────────────────────────
echo "$(date): Converting to JSON..." >> "$LOG"

python3 - <<'PY'
import csv, json, sys

rows = []
with open('/tmp/llm_judge_agg_refresh.csv') as f:
    for line in f:
        parts = line.strip().split(',')
        if len(parts) == 5:
            rows.append({
                "date": parts[0],
                "vendor": parts[1],
                "status": parts[2],
                "outcome": parts[3],
                "count": int(parts[4])
            })

with open('/tmp/llm_judge_data_refresh.json', 'w') as out:
    json.dump(rows, out)

print(f"Converted {len(rows)} rows to JSON")
PY

# ── 3. Rebuild index.html ───────────────────────────────────────────────────
echo "$(date): Rebuilding index.html..." >> "$LOG"

# Capture the date range for the header
MIN_DATE=$(awk -F',' 'NR==1{print $1}' "$CSV")
MAX_DATE=$(awk -F',' 'END{print $1}' "$CSV")

python3 - <<PYEOF
import json
from datetime import datetime

with open('/tmp/llm_judge_data_refresh.json') as f:
    data_json = f.read().strip()

min_date = open('/tmp/llm_judge_agg_refresh.csv').readline().split(',')[0]
with open('/tmp/llm_judge_agg_refresh.csv') as f:
    lines = f.readlines()
max_date = lines[-1].split(',')[0] if lines else min_date

# Format nicely e.g. "Jan 2026 – Jun 2026"
def fmt_date(d):
    try:
        return datetime.strptime(d, '%Y-%m-%d').strftime('%b %Y')
    except:
        return d

date_range_label = f"{fmt_date(min_date)} – {fmt_date(max_date)}"
refreshed_label  = f"Last refreshed: {datetime.now().strftime('%b %d, %Y')}"

html = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Voice Support LLM Judge Results</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.0/dist/chart.umd.min.js"></script>
<style>
  * {{ box-sizing: border-box; margin: 0; padding: 0; }}
  body {{ font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; background: #f0f2f5; color: #1a1a2e; }}
  header {{ background: #1a1a2e; color: white; padding: 18px 32px; display: flex; align-items: center; justify-content: space-between; gap: 16px; flex-wrap: wrap; }}
  header h1 {{ font-size: 20px; font-weight: 600; }}
  header .meta {{ font-size: 12px; opacity: 0.6; display: flex; flex-direction: column; align-items: flex-end; gap: 2px; }}
  .filters {{ background: white; padding: 16px 32px; display: flex; flex-wrap: wrap; gap: 20px; align-items: flex-end; border-bottom: 1px solid #e0e0e0; box-shadow: 0 2px 4px rgba(0,0,0,0.05); }}
  .filter-group {{ display: flex; flex-direction: column; gap: 4px; }}
  .filter-group label {{ font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.5px; color: #666; }}
  .filter-group select, .filter-group input {{ border: 1px solid #d0d0d0; border-radius: 6px; padding: 6px 10px; font-size: 13px; background: white; min-width: 140px; }}
  .filter-group select[multiple] {{ height: 80px; min-width: 160px; }}
  button#reset {{ background: #ff3008; color: white; border: none; border-radius: 6px; padding: 8px 16px; font-size: 13px; cursor: pointer; align-self: flex-end; }}
  button#reset:hover {{ background: #cc2606; }}
  .kpi-row {{ display: flex; gap: 16px; padding: 20px 32px; flex-wrap: wrap; }}
  .kpi {{ background: white; border-radius: 10px; padding: 16px 24px; flex: 1; min-width: 160px; box-shadow: 0 1px 4px rgba(0,0,0,0.08); }}
  .kpi .label {{ font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.5px; color: #888; margin-bottom: 6px; }}
  .kpi .value {{ font-size: 28px; font-weight: 700; }}
  .kpi.resolved .value {{ color: #22c55e; }}
  .kpi.escalated .value {{ color: #ef4444; }}
  .kpi.abandoned .value {{ color: #f97316; }}
  .kpi.na .value {{ color: #94a3b8; }}
  .charts-grid {{ display: grid; grid-template-columns: 1fr 1fr; gap: 20px; padding: 0 32px 32px; }}
  .chart-card {{ background: white; border-radius: 10px; padding: 20px; box-shadow: 0 1px 4px rgba(0,0,0,0.08); }}
  .chart-card.wide {{ grid-column: 1 / -1; }}
  .chart-header {{ display: flex; align-items: flex-start; justify-content: space-between; flex-wrap: wrap; gap: 10px; margin-bottom: 14px; }}
  .chart-title {{ font-size: 13px; font-weight: 600; color: #555; text-transform: uppercase; letter-spacing: 0.5px; padding-top: 4px; }}
  .chart-controls {{ display: flex; flex-wrap: wrap; align-items: center; gap: 8px; }}
  .ctrl-label {{ font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.5px; color: #888; }}
  .ctrl-select {{ border: 1px solid #d0d0d0; border-radius: 6px; padding: 4px 8px; font-size: 12px; background: white; cursor: pointer; }}
  .preset-btns {{ display: flex; gap: 4px; flex-wrap: wrap; }}
  .preset-btn {{ border: 1px solid #d0d0d0; background: white; border-radius: 5px; padding: 3px 9px; font-size: 11px; font-weight: 600; cursor: pointer; color: #555; transition: all 0.1s; }}
  .preset-btn:hover, .preset-btn.active {{ background: #1a1a2e; color: white; border-color: #1a1a2e; }}
  .split-tabs {{ display: flex; border: 1px solid #d0d0d0; border-radius: 6px; overflow: hidden; }}
  .split-tab {{ padding: 4px 12px; font-size: 11px; font-weight: 600; cursor: pointer; background: white; color: #555; border: none; border-right: 1px solid #d0d0d0; transition: all 0.1s; }}
  .split-tab:last-child {{ border-right: none; }}
  .split-tab.active {{ background: #1a1a2e; color: white; }}
  .ctrl-divider {{ width: 1px; height: 20px; background: #e0e0e0; margin: 0 2px; }}
  canvas {{ max-height: 320px; }}
  #tbl-wrap {{ overflow-x: auto; max-height: 300px; overflow-y: auto; }}
  table {{ width: 100%; border-collapse: collapse; font-size: 13px; }}
  th {{ position: sticky; top: 0; background: #f8f9fa; padding: 8px 12px; text-align: left; font-weight: 600; border-bottom: 2px solid #e0e0e0; }}
  td {{ padding: 7px 12px; border-bottom: 1px solid #f0f0f0; }}
  tr:hover td {{ background: #f9f9f9; }}
  .badge {{ display: inline-block; padding: 2px 8px; border-radius: 99px; font-size: 11px; font-weight: 600; }}
  .badge.resolved {{ background: #dcfce7; color: #16a34a; }}
  .badge.escalated {{ background: #fee2e2; color: #dc2626; }}
  .badge.abandoned {{ background: #ffedd5; color: #ea580c; }}
  .badge.not_applicable {{ background: #f1f5f9; color: #64748b; }}
</style>
</head>
<body>

<header>
  <div>
    <h1>Voice Support LLM Judge Results</h1>
  </div>
  <div class="meta">
    <span>PRODDB.DAVIDBORRELLI.VOICE_SUPPORT_LLM_JUDGE_RESULTS</span>
    <span>{date_range_label} &nbsp;·&nbsp; {refreshed_label}</span>
  </div>
</header>

<div class="filters">
  <div class="filter-group"><label>Date From</label><input type="date" id="f-date-from" value="{min_date}"></div>
  <div class="filter-group"><label>Date To</label><input type="date" id="f-date-to" value="{max_date}"></div>
  <div class="filter-group">
    <label>Vendor (multi)</label>
    <select id="f-vendor" multiple>
      <option value="giga_ml" selected>giga_ml</option>
      <option value="sierra" selected>sierra</option>
      <option value="vivo" selected>vivo</option>
    </select>
  </div>
  <div class="filter-group">
    <label>Dasher Delivery Status (multi)</label>
    <select id="f-status" multiple>
      <option value="1" selected>1</option><option value="2" selected>2</option>
      <option value="3" selected>3</option><option value="4" selected>4</option>
      <option value="5" selected>5</option><option value="6" selected>6</option>
    </select>
  </div>
  <div class="filter-group">
    <label>Outcome (multi)</label>
    <select id="f-outcome" multiple>
      <option value="resolved" selected>resolved</option>
      <option value="escalated" selected>escalated</option>
      <option value="abandoned" selected>abandoned</option>
      <option value="not_applicable" selected>not_applicable</option>
    </select>
  </div>
  <button id="reset">Reset Filters</button>
</div>

<div class="kpi-row">
  <div class="kpi"><div class="label">Total Calls</div><div class="value" id="kpi-total">—</div></div>
  <div class="kpi resolved"><div class="label">Resolved</div><div class="value" id="kpi-resolved">—</div></div>
  <div class="kpi escalated"><div class="label">Escalated</div><div class="value" id="kpi-escalated">—</div></div>
  <div class="kpi abandoned"><div class="label">Abandoned</div><div class="value" id="kpi-abandoned">—</div></div>
  <div class="kpi na"><div class="label">Not Applicable</div><div class="value" id="kpi-na">—</div></div>
  <div class="kpi resolved"><div class="label">Resolution Rate</div><div class="value" id="kpi-rate">—</div></div>
</div>

<div class="charts-grid">
  <div class="chart-card wide">
    <div class="chart-header">
      <span class="chart-title">Calls Over Time — Volume by Outcome</span>
      <div class="chart-controls">
        <div class="preset-btns" id="vol-presets">
          <button class="preset-btn" data-days="7"  data-gran="daily">7D Daily</button>
          <button class="preset-btn" data-days="14" data-gran="daily">14D Daily</button>
          <button class="preset-btn" data-days="28" data-gran="weekly">4W Weekly</button>
          <button class="preset-btn" data-days="84" data-gran="weekly">12W Weekly</button>
          <button class="preset-btn" data-days="0"  data-gran="monthly">All Monthly</button>
          <button class="preset-btn active" data-days="0" data-gran="weekly">All Weekly</button>
        </div>
        <div class="ctrl-divider"></div>
        <span class="ctrl-label">Granularity</span>
        <select id="vol-gran" class="ctrl-select">
          <option value="daily">Daily</option>
          <option value="weekly" selected>Weekly</option>
          <option value="monthly">Monthly</option>
        </select>
        <span class="ctrl-label">Last</span>
        <select id="vol-window" class="ctrl-select">
          <option value="7">7 days</option><option value="14">14 days</option>
          <option value="28">28 days</option><option value="60">60 days</option>
          <option value="90">90 days</option><option value="0" selected>All time</option>
        </select>
      </div>
    </div>
    <canvas id="chart-time"></canvas>
  </div>

  <div class="chart-card wide">
    <div class="chart-header">
      <span class="chart-title" id="pct-title">Calls Over Time — % of Outcome (All combined)</span>
      <div class="chart-controls">
        <div class="preset-btns" id="pct-presets">
          <button class="preset-btn" data-days="7"  data-gran="daily">7D Daily</button>
          <button class="preset-btn" data-days="14" data-gran="daily">14D Daily</button>
          <button class="preset-btn" data-days="28" data-gran="weekly">4W Weekly</button>
          <button class="preset-btn" data-days="84" data-gran="weekly">12W Weekly</button>
          <button class="preset-btn" data-days="0"  data-gran="monthly">All Monthly</button>
          <button class="preset-btn active" data-days="0" data-gran="weekly">All Weekly</button>
        </div>
        <div class="ctrl-divider"></div>
        <span class="ctrl-label">Granularity</span>
        <select id="pct-gran" class="ctrl-select">
          <option value="daily">Daily</option>
          <option value="weekly" selected>Weekly</option>
          <option value="monthly">Monthly</option>
        </select>
        <span class="ctrl-label">Last</span>
        <select id="pct-window" class="ctrl-select">
          <option value="7">7 days</option><option value="14">14 days</option>
          <option value="28">28 days</option><option value="60">60 days</option>
          <option value="90">90 days</option><option value="0" selected>All time</option>
        </select>
        <div class="ctrl-divider"></div>
        <span class="ctrl-label">Split by</span>
        <div class="split-tabs" id="split-tabs">
          <button class="split-tab active" data-split="combined">Combined</button>
          <button class="split-tab" data-split="vendor">Vendor</button>
          <button class="split-tab" data-split="status">Status</button>
        </div>
      </div>
    </div>
    <div id="pct-vendor-legend" style="display:none;gap:12px;flex-wrap:wrap;margin-bottom:10px;"></div>
    <canvas id="chart-pct"></canvas>
  </div>

  <div class="chart-card">
    <div class="chart-header"><span class="chart-title">Outcome Distribution</span></div>
    <canvas id="chart-donut"></canvas>
  </div>
  <div class="chart-card">
    <div class="chart-header"><span class="chart-title">Outcome by Vendor</span></div>
    <canvas id="chart-vendor"></canvas>
  </div>
  <div class="chart-card">
    <div class="chart-header"><span class="chart-title">Outcome by Dasher Delivery Status</span></div>
    <canvas id="chart-status"></canvas>
  </div>
  <div class="chart-card">
    <div class="chart-header"><span class="chart-title">Resolution Rate by Vendor (weekly)</span></div>
    <canvas id="chart-res-vendor"></canvas>
  </div>
  <div class="chart-card wide">
    <div class="chart-header"><span class="chart-title">Data Table (filtered, top 200)</span></div>
    <div id="tbl-wrap">
      <table>
        <thead><tr><th>Date</th><th>Vendor</th><th>Status</th><th>Outcome</th><th>Calls</th></tr></thead>
        <tbody id="tbl-body"></tbody>
      </table>
    </div>
  </div>
</div>

<script>
const RAW = {data_json};
const OUTCOMES = ['resolved','escalated','abandoned','not_applicable'];
const COLORS = {{ resolved:'#22c55e', escalated:'#ef4444', abandoned:'#f97316', not_applicable:'#94a3b8' }};
const VENDOR_COLORS = ['#6366f1','#ec4899','#0ea5e9'];
const STATUS_COLORS  = ['#14b8a6','#f59e0b','#8b5cf6','#06b6d4','#f43f5e','#84cc16'];
let charts = {{}};

function getSelected(id) {{ return Array.from(document.getElementById(id).selectedOptions).map(o=>o.value); }}
function fmt(n) {{ return n>=1e6?(n/1e6).toFixed(1)+'M':n>=1e3?(n/1e3).toFixed(1)+'K':n.toLocaleString(); }}
function getBucketKey(dateStr, gran) {{
  if(gran==='daily') return dateStr;
  if(gran==='monthly') return dateStr.slice(0,7);
  const dt=new Date(dateStr+'T00:00:00'), day=dt.getDay(), m=new Date(dt);
  m.setDate(dt.getDate()-((day+6)%7)); return m.toISOString().slice(0,10);
}}
function allBuckets(minDate, maxDate, gran) {{
  const result=[],seen=new Set();
  const cur=new Date(minDate+'T00:00:00'), end=new Date(maxDate+'T00:00:00');
  while(cur<=end){{
    const key=getBucketKey(cur.toISOString().slice(0,10),gran);
    if(!seen.has(key)){{seen.add(key);result.push(key);}}
    if(gran==='daily') cur.setDate(cur.getDate()+1);
    else if(gran==='weekly') cur.setDate(cur.getDate()+7);
    else cur.setMonth(cur.getMonth()+1);
  }} return result;
}}
function applyWindow(data, windowId) {{
  const maxDate = data.map(r=>r.date).reduce((a,b)=>a>b?a:b, '');
  const days=parseInt(document.getElementById(windowId).value);
  if(!days||!maxDate) return data;
  const cutoff=new Date(maxDate+'T00:00:00');
  cutoff.setDate(cutoff.getDate()-days+1);
  return data.filter(r=>r.date>=cutoff.toISOString().slice(0,10));
}}
function filter() {{
  const dFrom=document.getElementById('f-date-from').value;
  const dTo=document.getElementById('f-date-to').value;
  const vendors=getSelected('f-vendor');
  const statuses=getSelected('f-status');
  const outcomes=getSelected('f-outcome');
  return RAW.filter(r=>r.date>=dFrom&&r.date<=dTo&&vendors.includes(r.vendor)&&statuses.includes(r.status)&&outcomes.includes(r.outcome));
}}
function destroyChart(id) {{ if(charts[id]){{charts[id].destroy();delete charts[id];}} }}
function dateRange(data) {{
  const dates=data.map(r=>r.date);
  return [dates.reduce((a,b)=>a<b?a:b), dates.reduce((a,b)=>a>b?a:b)];
}}

function render() {{
  const data=filter();
  const totals={{}};let total=0;
  for(const r of data){{totals[r.outcome]=(totals[r.outcome]||0)+r.count;total+=r.count;}}
  document.getElementById('kpi-total').textContent=fmt(total);
  document.getElementById('kpi-resolved').textContent=fmt(totals['resolved']||0);
  document.getElementById('kpi-escalated').textContent=fmt(totals['escalated']||0);
  document.getElementById('kpi-abandoned').textContent=fmt(totals['abandoned']||0);
  document.getElementById('kpi-na').textContent=fmt(totals['not_applicable']||0);
  const act=(totals['resolved']||0)+(totals['escalated']||0)+(totals['abandoned']||0);
  document.getElementById('kpi-rate').textContent=act?((totals['resolved']||0)/act*100).toFixed(1)+'%':'—';
  renderVolumeChart(data); renderPctChart(data);

  destroyChart('donut');
  charts['donut']=new Chart(document.getElementById('chart-donut'),{{
    type:'doughnut',
    data:{{labels:OUTCOMES,datasets:[{{data:OUTCOMES.map(o=>totals[o]||0),backgroundColor:Object.values(COLORS)}}]}},
    options:{{responsive:true,maintainAspectRatio:true,plugins:{{legend:{{position:'right'}}}}}}
  }});

  const vendors=[...new Set(data.map(r=>r.vendor))].sort();
  const vd={{}};for(const r of data){{if(!vd[r.vendor])vd[r.vendor]={{}};vd[r.vendor][r.outcome]=(vd[r.vendor][r.outcome]||0)+r.count;}}
  destroyChart('vendor');
  charts['vendor']=new Chart(document.getElementById('chart-vendor'),{{
    type:'bar',
    data:{{labels:vendors,datasets:OUTCOMES.map(o=>({{'label':o,stack:'a',data:vendors.map(v=>(vd[v]||{{}})[o]||0),backgroundColor:COLORS[o]}}))}},
    options:{{responsive:true,maintainAspectRatio:true,plugins:{{legend:{{position:'top'}}}},scales:{{x:{{stacked:true}},y:{{stacked:true}}}}}}
  }});

  const statuses=[...new Set(data.map(r=>r.status))].sort();
  const sd={{}};for(const r of data){{if(!sd[r.status])sd[r.status]={{}};sd[r.status][r.outcome]=(sd[r.status][r.outcome]||0)+r.count;}}
  destroyChart('status');
  charts['status']=new Chart(document.getElementById('chart-status'),{{
    type:'bar',
    data:{{labels:statuses,datasets:OUTCOMES.map(o=>({{'label':o,stack:'a',data:statuses.map(s=>(sd[s]||{{}})[o]||0),backgroundColor:COLORS[o]}}))}},
    options:{{responsive:true,maintainAspectRatio:true,plugins:{{legend:{{position:'top'}}}},scales:{{x:{{stacked:true}},y:{{stacked:true}}}}}}
  }});

  const vwm={{}};
  for(const r of data){{
    const wk=getBucketKey(r.date,'weekly'),k=r.vendor+'||'+wk;
    if(!vwm[k])vwm[k]={{resolved:0,actionable:0}};
    if(r.outcome==='resolved')vwm[k].resolved+=r.count;
    if(['resolved','escalated','abandoned'].includes(r.outcome))vwm[k].actionable+=r.count;
  }}
  const weeks=[...new Set(data.map(r=>getBucketKey(r.date,'weekly')))].sort();
  destroyChart('res-vendor');
  charts['res-vendor']=new Chart(document.getElementById('chart-res-vendor'),{{
    type:'line',
    data:{{labels:weeks,datasets:vendors.map((v,i)=>({{'label':v,spanGaps:true,tension:0.3,fill:false,
      borderColor:VENDOR_COLORS[i%VENDOR_COLORS.length],backgroundColor:VENDOR_COLORS[i%VENDOR_COLORS.length]+'22',
      data:weeks.map(w=>{{const k=v+'||'+w,d=vwm[k];return d&&d.actionable?+(d.resolved/d.actionable*100).toFixed(1):null;}})
    }})) }},
    options:{{responsive:true,maintainAspectRatio:true,plugins:{{legend:{{position:'top'}}}},
      scales:{{y:{{title:{{display:true,text:'Resolution Rate %'}},min:0,max:100}}}}}}
  }});

  const tbody=document.getElementById('tbl-body');
  tbody.innerHTML=data.slice(0,200).sort((a,b)=>b.date.localeCompare(a.date)||a.vendor.localeCompare(b.vendor))
    .map(r=>`<tr><td>${{r.date}}</td><td>${{r.vendor}}</td><td>${{r.status}}</td><td><span class="badge ${{r.outcome}}">${{r.outcome}}</span></td><td>${{r.count.toLocaleString()}}</td></tr>`)
    .join('');
}}

function renderVolumeChart(baseData) {{
  const gran=document.getElementById('vol-gran').value;
  const data=applyWindow(baseData,'vol-window');
  if(!data.length){{destroyChart('time');return;}}
  const [minD,maxD]=dateRange(data);
  const buckets=allBuckets(minD,maxD,gran);
  const bm={{}};
  for(const r of data){{const bk=getBucketKey(r.date,gran);if(!bm[bk])bm[bk]={{}};bm[bk][r.outcome]=(bm[bk][r.outcome]||0)+r.count;}}
  destroyChart('time');
  charts['time']=new Chart(document.getElementById('chart-time'),{{
    type:'bar',
    data:{{labels:buckets,datasets:OUTCOMES.map(o=>({{'label':o,stack:'a',data:buckets.map(b=>(bm[b]||{{}})[o]||0),backgroundColor:COLORS[o]}}))}},
    options:{{responsive:true,maintainAspectRatio:true,plugins:{{legend:{{position:'top'}}}},scales:{{x:{{stacked:true}},y:{{stacked:true}}}}}}
  }});
}}

function renderPctChart(baseData) {{
  const gran=document.getElementById('pct-gran').value;
  const split=document.querySelector('.split-tab.active').dataset.split;
  const splitKey=split==='vendor'?'vendor':split==='status'?'status':null;
  const titleMap={{combined:'All combined',vendor:'per Vendor',status:'per Dasher Status'}};
  document.getElementById('pct-title').textContent=`Calls Over Time — % of Outcome (${{titleMap[split]}})`;

  const dFrom=document.getElementById('f-date-from').value;
  const dTo=document.getElementById('f-date-to').value;
  const vendors=getSelected('f-vendor');
  const statuses=getSelected('f-status');
  const rawFiltered=RAW.filter(r=>r.date>=dFrom&&r.date<=dTo&&vendors.includes(r.vendor)&&statuses.includes(r.status));
  const rawWindowed=applyWindow(rawFiltered,'pct-window');

  if(!rawWindowed.length){{destroyChart('pct');return;}}
  const [minD,maxD]=dateRange(rawWindowed);
  const buckets=allBuckets(minD,maxD,gran);
  const splitVals=splitKey?[...new Set(rawWindowed.map(r=>r[splitKey]))].sort():['all'];
  const palette=split==='vendor'?VENDOR_COLORS:split==='status'?STATUS_COLORS:null;

  const fullAgg={{}};
  for(const r of rawWindowed){{
    const sv=splitKey?r[splitKey]:'all';
    const bk=getBucketKey(r.date,gran);
    if(!fullAgg[sv])fullAgg[sv]={{}};
    if(!fullAgg[sv][bk])fullAgg[sv][bk]={{}};
    fullAgg[sv][bk][r.outcome]=(fullAgg[sv][bk][r.outcome]||0)+r.count;
  }}

  const selectedOutcomes=getSelected('f-outcome');
  const datasets=[];

  if(split==='combined') {{
    selectedOutcomes.forEach(o=>{{
      datasets.push({{
        label:o, stack:'combined', backgroundColor:COLORS[o],
        data:buckets.map(bk=>{{
          const bd=fullAgg['all']?.[bk]||{{}};
          const tot=Object.values(bd).reduce((s,v)=>s+v,0);
          return tot>0?parseFloat(((bd[o]||0)/tot*100).toFixed(1)):0;
        }})
      }});
    }});
  }} else {{
    splitVals.forEach((sv,si)=>{{
      const borderColor=(palette||VENDOR_COLORS)[si%(palette||VENDOR_COLORS).length];
      selectedOutcomes.forEach(o=>{{
        datasets.push({{
          label:`${{sv}} — ${{o}}`, stack:sv,
          backgroundColor:COLORS[o], borderColor:borderColor, borderWidth:3, borderSkipped:false,
          data:buckets.map(bk=>{{
            const bd=fullAgg[sv]?.[bk]||{{}};
            const tot=Object.values(bd).reduce((s,v)=>s+v,0);
            return tot>0?parseFloat(((bd[o]||0)/tot*100).toFixed(1)):0;
          }})
        }});
      }});
    }});
  }}

  const legendEl=document.getElementById('pct-vendor-legend');
  if(split==='combined') {{ legendEl.style.display='none'; }}
  else {{
    legendEl.style.display='flex';
    legendEl.innerHTML=splitVals.map((sv,si)=>{{
      const c=(palette||VENDOR_COLORS)[si%(palette||VENDOR_COLORS).length];
      return `<span style="display:inline-flex;align-items:center;gap:5px;font-size:12px;font-weight:600;color:#333;"><span style="display:inline-block;width:14px;height:14px;border-radius:3px;border:3px solid ${{c}};background:white;"></span>${{sv}}</span>`;
    }}).join('');
  }}

  destroyChart('pct');
  charts['pct']=new Chart(document.getElementById('chart-pct'),{{
    type:'bar', data:{{labels:buckets,datasets}},
    options:{{
      responsive:true, maintainAspectRatio:true,
      interaction:{{mode:'index',intersect:false}},
      plugins:{{legend:{{position:'top'}},tooltip:{{callbacks:{{label:ctx=>`${{ctx.dataset.label}}: ${{ctx.parsed.y!=null?ctx.parsed.y.toFixed(1)+'%':'—'}}`}}}}}},
      scales:{{x:{{stacked:true}},y:{{stacked:true,min:0,max:100,ticks:{{callback:v=>v+'%'}},title:{{display:true,text:'% of calls in period'}}}}}}
    }}
  }});
}}

function wirePresets(groupId, granId, windowId, renderFn) {{
  document.getElementById(groupId).addEventListener('click',e=>{{
    const btn=e.target.closest('.preset-btn');if(!btn)return;
    document.querySelectorAll(`#${{groupId}} .preset-btn`).forEach(b=>b.classList.remove('active'));
    btn.classList.add('active');
    document.getElementById(granId).value=btn.dataset.gran;
    document.getElementById(windowId).value=btn.dataset.days;
    renderFn(filter());
  }});
  [granId,windowId].forEach(id=>document.getElementById(id).addEventListener('change',()=>{{
    document.querySelectorAll(`#${{groupId}} .preset-btn`).forEach(b=>b.classList.remove('active'));
    renderFn(filter());
  }}));
}}
wirePresets('vol-presets','vol-gran','vol-window', renderVolumeChart);
wirePresets('pct-presets','pct-gran','pct-window', renderPctChart);

document.getElementById('split-tabs').addEventListener('click',e=>{{
  const tab=e.target.closest('.split-tab');if(!tab)return;
  document.querySelectorAll('.split-tab').forEach(t=>t.classList.remove('active'));
  tab.classList.add('active'); renderPctChart(filter());
}});

['f-date-from','f-date-to','f-vendor','f-status','f-outcome'].forEach(id=>
  document.getElementById(id).addEventListener('change',render)
);

document.getElementById('reset').addEventListener('click',()=>{{
  document.getElementById('f-date-from').value='{min_date}';
  document.getElementById('f-date-to').value='{max_date}';
  ['f-vendor','f-status','f-outcome'].forEach(id=>Array.from(document.getElementById(id).options).forEach(o=>o.selected=true));
  [['vol-presets','vol-gran','vol-window'],['pct-presets','pct-gran','pct-window']].forEach(([gid,gran,win])=>{{
    document.getElementById(gran).value='weekly'; document.getElementById(win).value='0';
    document.querySelectorAll(`#${{gid}} .preset-btn`).forEach(b=>b.classList.remove('active'));
    document.querySelector(`#${{gid}} .preset-btn[data-days="0"][data-gran="weekly"]`).classList.add('active');
  }});
  document.querySelectorAll('.split-tab').forEach(t=>t.classList.remove('active'));
  document.querySelector('.split-tab[data-split="combined"]').classList.add('active');
  render();
}});

render();
</script>
</body>
</html>"""

with open('/Users/peter.chao/Desktop/peter-brief/index.html', 'w') as f:
    f.write(html)
print("Built index.html successfully")
PYEOF

echo "$(date): Built index.html" >> "$LOG"

# ── 4. Commit and push to GitHub ────────────────────────────────────────────
echo "$(date): Pushing to GitHub..." >> "$LOG"

cd "$PROJECT"

# Configure git if needed
git config user.email "peter.chao@doordash.com" 2>/dev/null || true
git config user.name "Peter Chao" 2>/dev/null || true

# Use gh to set the credential helper so push works without password prompts
gh auth setup-git 2>/dev/null || true

# Stage and commit
git add index.html
git commit -m "Dashboard data refresh — $(date '+%Y-%m-%d')" || {
  echo "$(date): No changes to commit (data unchanged)" >> "$LOG"
  exit 0
}

# Push — pull first in case of remote changes
git pull origin main --rebase 2>/dev/null || git pull origin main 2>/dev/null || true
git push origin main >> "$LOG" 2>&1

echo "$(date): Done. Dashboard updated at https://peter-chao-dd.github.io/support-ops/" >> "$LOG"
