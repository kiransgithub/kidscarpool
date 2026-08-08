if ('serviceWorker' in navigator) {
  navigator.serviceWorker.register('./service-worker-v25.js', { scope: './' })
    .catch(error => console.warn('KCP natural schedule service worker:',error))
}
