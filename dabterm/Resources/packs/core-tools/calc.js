// calc <expression>  — arithmetic with Math.* available (e.g. calc "2^10", calc "sqrt(2)*pi")
let expr = process.argv.slice(2).join(' ') || readStdin();
if (!expr.trim()) { console.error('usage: calc <expr>'); process.exit(1); }
expr = expr.replace(/\^/g, '**').replace(/\bpi\b/g, 'Math.PI').replace(/\be\b/g, 'Math.E')
  .replace(/\b(sqrt|abs|floor|ceil|round|sin|cos|tan|log|log2|log10|exp|pow|min|max|hypot|trunc)\(/g, 'Math.$1(');
if (!/^[\d\s+\-*/%().,eE^<>&|~xXa-fA-FMathPIsqrtbfloceilundgpwmnhyp_]*$/.test(expr)) { console.error('calc: unsupported characters'); process.exit(1); }
try {
  const v = Function('"use strict"; return (' + expr + ')')();
  console.log(typeof v === 'number' && !Number.isInteger(v) ? +v.toPrecision(12) : v);
} catch (e) { console.error('calc: ' + e.message); process.exit(1); }
