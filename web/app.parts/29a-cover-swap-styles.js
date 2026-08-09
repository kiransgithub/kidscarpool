if (!document.querySelector('link[href="./cover-swaps.css"]')) {
  const coverSwapStyles = document.createElement('link')
  coverSwapStyles.rel = 'stylesheet'
  coverSwapStyles.href = './cover-swaps.css'
  document.head.appendChild(coverSwapStyles)
}
