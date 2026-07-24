// Inlined from the soredemo vector brand (soredemo-glyph). The そ glyph on the
// brand navy, with the cursor + click-spark motif. Inlined as a component so no
// remote/image asset is fetched — required for the loopback security posture.
export function Glyph({ className }: { className?: string }): JSX.Element {
  return (
    <svg
      className={className}
      viewBox="0 0 1024 1024"
      xmlns="http://www.w3.org/2000/svg"
      role="img"
      aria-label="Soredemo"
    >
      <circle cx="512" cy="512" r="455" fill="#0B0E13" />
      <path
        d="m 349.55,228.65 3.54,75.52 c 18.88,-2.36 38.35,-4.13 53.1,-5.31 24.19,-2.36 96.76,-5.9 120.95,-7.67 -36.58,32.45 -113.28,99.71 -165.79,133.93 -31.27,3.54 -72.57,8.85 -103.84,11.8 l 7.08,71.39 c 59,-10.03 125.08,-18.88 179.36,-23.6 -22.42,20.65 -43.07,57.23 -43.07,93.22 0,98.53 87.91,143.96 238.95,137.47 l 15.93,-77.29 c -22.42,1.77 -57.23,1.77 -90.27,-1.77 -52.51,-5.9 -89.09,-24.19 -89.09,-70.8 0,-48.38 44.84,-86.73 99.12,-93.81 35.99,-5.31 94.99,-4.72 151.63,-1.77 v -69.62 c -71.98,0 -169.92,6.49 -248.98,14.16 40.71,-31.27 98.53,-80.24 140.42,-113.87 12.39,-10.03 34.22,-24.19 46.61,-32.45 L 618.59,213.9 c -8.26,2.95 -21.83,5.31 -40.71,7.67 -35.99,3.54 -146.91,8.85 -172.28,8.85 -20.06,0 -37.17,-0.59 -56.05,-1.77 z"
        fill="#F4F4F7"
        stroke="#F4F4F7"
        strokeWidth="18"
        strokeLinejoin="round"
        paintOrder="stroke fill"
      />
      <path
        d="M 674 654 L 674 825 L 723 778 L 764 860 L 810 837 L 771 758 L 835 758 Z"
        fill="#0B0E13"
        stroke="#F4F4F7"
        strokeWidth="24"
        strokeLinejoin="round"
      />
      <g stroke="#6EA8D6" strokeWidth="20" strokeLinecap="round">
        <path d="M 730 638 L 720 598" />
        <path d="M 772 648 L 802 616" />
        <path d="M 791 692 L 833 692" />
      </g>
    </svg>
  );
}
