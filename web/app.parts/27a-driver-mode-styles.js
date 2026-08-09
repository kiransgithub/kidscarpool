if (!document.querySelector('link[href="./driver-mode.css"]')) {
  const driverModeStyles = document.createElement('link')
  driverModeStyles.rel = 'stylesheet'
  driverModeStyles.href = './driver-mode.css'
  document.head.appendChild(driverModeStyles)
}
