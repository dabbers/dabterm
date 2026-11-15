// jsonfmt [-c] [-s] [file]   pretty-print (default), -c compact, -s sort keys
const fs = require('fs');
const args = process.argv.slice(2);
const compact = args.includes('-c'), sort = args.includes('-s');
const file = args.find(a => !a.startsWith('-'));
const text = file ? fs.readFileSync(file, 'utf8') : readStdin();
if (!text.trim()) { console.error('jsonfmt: no input (pipe JSON or give a file)'); process.exit(1); }
function sortKeys(v) {
  if (Array.isArray(v)) return v.map(sortKeys);
  if (v && typeof v === 'object') return Object.keys(v).sort().reduce((o, k) => (o[k] = sortKeys(v[k]), o), {});
  return v;
}
try {
  let obj = JSON.parse(text);
  if (sort) obj = sortKeys(obj);
  console.log(compact ? JSON.stringify(obj) : JSON.stringify(obj, null, 2));
} catch (e) { console.error('jsonfmt: ' + e.message); process.exit(1); }
