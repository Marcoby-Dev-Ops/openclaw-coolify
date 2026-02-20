const http = require('http');

const NEXUS_API_URL = process.env.NEXUS_API_URL || 'http://localhost:3001';
const API_KEY = process.env.NEXUS_OPENCLAW_API_KEY || 'sk-openclaw-f8e9d1c2b3a4z5y6x7w8v9u0t1s2r3q4';

console.log(`Checking connection to Nexus API at: ${NEXUS_API_URL}`);

const url = new URL(`${NEXUS_API_URL}/healthz`);

const req = http.get(url, (res) => {
    console.log(`STATUS: ${res.statusCode}`);
    res.setEncoding('utf8');
    res.on('data', (chunk) => {
        console.log(`BODY: ${chunk}`);
    });
    res.on('end', () => {
        if (res.statusCode === 200) {
            console.log('✅ Connection successful!');
            process.exit(0);
        } else {
            console.error(`❌ Connection failed with status: ${res.statusCode}`);
            process.exit(1);
        }
    });
});

req.on('error', (e) => {
    console.error(`❌ Problem with request: ${e.message}`);
    process.exit(1);
});

req.end();
