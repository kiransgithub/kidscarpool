if (!document.querySelector('link[href="./all-group-home.css"]')) {
  const allGroupStyles = document.createElement('link')
  allGroupStyles.rel = 'stylesheet'
  allGroupStyles.href = './all-group-home.css'
  document.head.appendChild(allGroupStyles)
}
