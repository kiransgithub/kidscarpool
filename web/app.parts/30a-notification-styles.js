if (!document.querySelector('link[href="./notifications.css"]')) {
  const notificationStyles = document.createElement('link')
  notificationStyles.rel = 'stylesheet'
  notificationStyles.href = './notifications.css'
  document.head.appendChild(notificationStyles)
}
