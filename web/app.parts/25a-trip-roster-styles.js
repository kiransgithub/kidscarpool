if (!document.querySelector('link[href="./trip-roster.css"]')) {
  const rosterStyles = document.createElement('link')
  rosterStyles.rel = 'stylesheet'
  rosterStyles.href = './trip-roster.css'
  document.head.appendChild(rosterStyles)
}
