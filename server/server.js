import { createVoiceServer } from './app.js';

let voice;
try {
  voice = createVoiceServer({
    apiKey: process.env.API_KEY,
    publicBaseUrl: process.env.PUBLIC_BASE_URL,
    // على Render الاتصال HTTPS، فنفعّل الكوكي الآمن. للتجربة المحلية على http: LOCAL_DEV=1
    secureCookies: process.env.LOCAL_DEV !== '1',
  });
} catch (err) {
  console.error(`[fatal] ${err.message}`);
  process.exit(1);
}

const port = Number(process.env.PORT) || 3000;

voice.server.listen(port, '0.0.0.0', () => {
  console.log(`[ok] New Town Voice listening on port ${port}`);
});

async function shutdown() {
  await voice.close();
  process.exit(0);
}
process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);
