if (!document.querySelector('link[href="./role-dashboards.css"]')) {
  const roleStyles = document.createElement('link')
  roleStyles.rel = 'stylesheet'
  roleStyles.href = './role-dashboards.css'
  document.head.appendChild(roleStyles)
}
