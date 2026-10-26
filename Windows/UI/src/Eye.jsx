import React,{useEffect,useRef,useState} from 'react';

import {renderEye} from './eye-art.mjs';
export {renderEye} from './eye-art.mjs';

export default function Eye({active,progress,progressRef,description}) {
  const pre=useRef(null),props=useRef({active,progress});
  const [reduced,setReduced]=useState(false);
  props.current={active,progress};
  useEffect(()=>{
    const media=matchMedia('(prefers-reduced-motion: reduce)');
    const update=()=>setReduced(media.matches);update();media.addEventListener('change',update);
    return()=>media.removeEventListener('change',update);
  },[]);
  useEffect(()=>{
    let frame,last=0,gx=0,gy=0,wasActive=false,activeSince=0;const start=performance.now();
    function animate(now) {
      if(now-last<65){frame=requestAnimationFrame(animate);return;}last=now;
      const t=(now-start)/1000,phase=t%6.8;
      if(props.current.active&&!wasActive)activeSince=t;
      wasActive=props.current.active;
      let opening=1,tx=0,ty=0;
      if(!reduced) {
        if(phase>5.85&&phase<6.19)opening=1-Math.sin(Math.PI*(phase-5.85)/.34)**2;
        const age=t-activeSince;
        const watch=props.current.active?(age<1.8?2:Math.floor(age/3.3)%3):Math.floor(t/3.3)%3;
        tx=watch===0?-.12:.16;ty=-.04;
        if(watch===2&&props.current.active&&progressRef.current&&pre.current) {
          const eye=pre.current.getBoundingClientRect(),bar=progressRef.current.getBoundingClientRect();
          const end=bar.left+bar.width*props.current.progress;
          tx=Math.max(-.23,Math.min(.23,(end-(eye.left+eye.width/2))/eye.width*.65));
          ty=Math.max(-.18,Math.min(.3,(bar.top-(eye.top+eye.height/2))/eye.height*.4));
        } else if(watch===2) {tx=.1;ty=.13;}
      }
      gx+=(tx-gx)*.16;gy+=(ty-gy)*.16;
      if(pre.current)pre.current.textContent=renderEye(gx,gy,opening);
      if(!reduced)frame=requestAnimationFrame(animate);
    }
    frame=requestAnimationFrame(animate);
    return()=>cancelAnimationFrame(frame);
  },[reduced,progressRef]);
  return <div className="eye-stage" role="img" aria-label={description}><pre ref={pre} aria-hidden="true">{renderEye(0,0,1)}</pre></div>;
}
