if (!document.querySelector('link[href="./safe-trip-state.css"]')) {
  const safeTripStyles = document.createElement('link')
  safeTripStyles.rel = 'stylesheet'
  safeTripStyles.href = './safe-trip-state.css'
  document.head.appendChild(safeTripStyles)
}
