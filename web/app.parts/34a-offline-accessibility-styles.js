if (!document.querySelector('link[href="./offline-accessibility.css"]')) {
  const offlineStyles = document.createElement('link')
  offlineStyles.rel = 'stylesheet'
  offlineStyles.href = './offline-accessibility.css'
  document.head.appendChild(offlineStyles)
}
