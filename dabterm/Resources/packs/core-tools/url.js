// urlencode / urldecode: operate on arguments, or stdin when none are given
const name = require('path').basename(process.argv[1], '.js'); // not reliable for aliases; use env
const mode = (process.env.DABTERM_CMD || '').startsWith('urld') ? 'decode' : 'encode';
const input = process.argv.length > 2 ? process.argv.slice(2).join(' ') : readStdin().replace(/\n$/, '');
console.log(mode === 'decode' ? decodeURIComponent(input) : encodeURIComponent(input));
