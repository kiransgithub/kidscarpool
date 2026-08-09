if ('serviceWorker' in navigator) {
  navigator.serviceWorker.register('./service-worker-v24.js', { scope: './' })
    .catch(error => console.warn('KCP release service worker:',error))
}
