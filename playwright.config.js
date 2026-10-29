const { defineConfig } = require('@playwright/test');
module.exports = defineConfig({
  testDir: './site-tests',
  timeout: 60000,
  use: { baseURL: 'http://127.0.0.1:4197' },
  webServer: { command: 'python3 -m http.server 4197 --bind 127.0.0.1 --directory _site', port: 4197 },
  projects: ['chromium', 'firefox', 'webkit'].flatMap(browserName => [375, 1440].map(width => ({
    name: `${browserName}-${width}`, use: { browserName, viewport: { width, height: 900 } }
  }))),
  reporter: [['list'], ['html', { open: 'never' }]],
});
