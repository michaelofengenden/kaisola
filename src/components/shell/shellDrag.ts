/**
 * While ANY shell drag runs (card heads, column grips, the canvas edge),
 * iframes/webviews must stop eating pointer events — a PDF or browser card
 * under the cursor otherwise freezes the drag mid-flight.
 */
export const shellDrag = {
  start: () => document.body.setAttribute('data-shell-drag', '1'),
  end: () => document.body.removeAttribute('data-shell-drag'),
}
