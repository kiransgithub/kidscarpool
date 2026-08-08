if (!document.querySelector('link[href="./schedule-impact.css"]')) {
  const impactStyles = document.createElement('link')
  impactStyles.rel = 'stylesheet'
  impactStyles.href = './schedule-impact.css'
  document.head.appendChild(impactStyles)
}
