if (!document.querySelector('link[href="./adaptive-invitations.css"]')) {
  const invitationStyles = document.createElement('link')
  invitationStyles.rel = 'stylesheet'
  invitationStyles.href = './adaptive-invitations.css'
  document.head.appendChild(invitationStyles)
}
