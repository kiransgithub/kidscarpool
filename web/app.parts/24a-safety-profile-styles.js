if (!document.querySelector('link[href="./safety-profiles.css"]')) {
  const safetyStyles = document.createElement('link')
  safetyStyles.rel = 'stylesheet'
  safetyStyles.href = './safety-profiles.css'
  document.head.appendChild(safetyStyles)
}
