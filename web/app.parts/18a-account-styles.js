if (!document.querySelector('link[href="./account-auth.css"]')) {
  const accountStyles = document.createElement('link')
  accountStyles.rel = 'stylesheet'
  accountStyles.href = './account-auth.css'
  document.head.appendChild(accountStyles)
}
