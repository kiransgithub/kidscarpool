if (!document.querySelector('link[href="./natural-schedule.css"]')) {
  const naturalScheduleStyles = document.createElement('link')
  naturalScheduleStyles.rel = 'stylesheet'
  naturalScheduleStyles.href = './natural-schedule.css'
  document.head.appendChild(naturalScheduleStyles)
}
