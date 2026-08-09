if (!document.querySelector('link[href="./fairness.css"]')) {
  const fairnessStyles = document.createElement('link')
  fairnessStyles.rel = 'stylesheet'
  fairnessStyles.href = './fairness.css'
  document.head.appendChild(fairnessStyles)
}
