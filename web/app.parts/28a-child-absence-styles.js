if (!document.querySelector('link[href="./child-absence.css"]')) {
  const absenceStyles = document.createElement('link')
  absenceStyles.rel = 'stylesheet'
  absenceStyles.href = './child-absence.css'
  document.head.appendChild(absenceStyles)
}
