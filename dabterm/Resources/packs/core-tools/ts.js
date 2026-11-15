// ts [now|<epoch seconds|ms>|<ISO date>]  — show a moment in several formats
const a = process.argv.slice(2).join(' ').trim();
let d;
if (!a || a === 'now') d = new Date();
else if (/^\d+$/.test(a)) d = new Date(a.length > 10 ? Number(a) : Number(a) * 1000);
else d = new Date(a);
if (isNaN(d)) { console.error('ts: cannot parse ' + JSON.stringify(a)); process.exit(1); }
const pad = n => String(n).padStart(2, '0');
console.log('epoch     ' + Math.floor(d.getTime() / 1000));
console.log('epoch ms  ' + d.getTime());
console.log('iso       ' + d.toISOString());
console.log('local     ' + `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`);
console.log('utc       ' + d.toUTCString());
const diff = (Date.now() - d.getTime()) / 1000;
const abs = Math.abs(diff), unit = abs < 60 ? [abs, 's'] : abs < 3600 ? [abs / 60, 'min'] : abs < 86400 ? [abs / 3600, 'h'] : [abs / 86400, 'd'];
console.log('relative  ' + (diff >= 0 ? `${unit[0].toFixed(1)}${unit[1]} ago` : `in ${unit[0].toFixed(1)}${unit[1]}`));
