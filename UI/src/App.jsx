import React,{useEffect,useRef,useState} from 'react';
import {createRoot} from 'react-dom/client';
import Eye from './Eye.jsx';

const copy={
 en:{watching:'WATCHING THE BYTES',ready:'READY WHEN YOU ARE',complete:'BATCH COMPLETE',cancelled:'CANCELLED',queue:'QUEUE',files:'FILES',queued:'Queued',inspecting:'Reading source',encoding:'Compressing',verifying:'Checking result',ok:'Saved',skipped:'Unchanged',error:'Not processed',cancel:'Cancel',cancelling:'Stopping…',done:'Done',preparing:'Waiting for folder access',empty:'Select videos in Finder, then choose\nCMPRS — Compress video.',eye:'A blinking ASCII eye watching compression progress.'},
 ru:{watching:'СЛЕДИМ ЗА БАЙТАМИ',ready:'ГОТОВ К РАБОТЕ',complete:'ОЧЕРЕДЬ ЗАВЕРШЕНА',cancelled:'ОТМЕНЕНО',queue:'ОЧЕРЕДЬ',files:'ФАЙЛОВ',queued:'В очереди',inspecting:'Читаем исходник',encoding:'Сжимаем',verifying:'Проверяем результат',ok:'Сохранено',skipped:'Без изменений',error:'Не обработан',cancel:'Отмена',cancelling:'Останавливаем…',done:'Готово',preparing:'Ожидаем доступ к папке',empty:'Выбери видео в Finder, затем\nCMPRS — Сжать видео.',eye:'Моргающий ASCII-глаз, который следит за прогрессом сжатия.'}
};
const initial={language:'en',working:false,preparing:false,cancelling:false,finished:false,progress:0,stage:'queued',files:[],savedBytes:0,message:null};
function send(action){window.webkit?.messageHandlers?.cmprs?.postMessage({action});}
function size(value){if(value==null)return '—';let n=value,u=0;const units=['B','KB','MB','GB','TB'];while(n>=1000&&u<4){n/=1000;u++;}return `${n.toFixed(u&&n<10?1:0)} ${units[u]}`;}
function App(){
 const [state,setState]=useState(initial),progressRef=useRef(null),activeRow=useRef(null);
 const t=copy[state.language]||copy.en,busy=state.working||state.preparing;
 const percent=Math.floor(Math.max(0,Math.min(1,state.progress))*100);
 const completed=state.files.filter(f=>['ok','skipped','error','cancelled'].includes(f.status)).length;
 const current=state.files.findIndex(f=>['inspecting','encoding','verifying'].includes(f.status));
 useEffect(()=>{window.cmprsReceive=value=>{setState({...initial,...value});document.documentElement.lang=value.language||'en';};send('ready');return()=>delete window.cmprsReceive;},[]);
 useEffect(()=>{activeRow.current?.scrollIntoView({block:'nearest'});},[current]);
 useEffect(()=>{const onKey=e=>{if(e.key==='Escape'&&busy){e.preventDefault();send('cancel');}else if(e.key==='Enter'&&!busy){e.preventDefault();send('done');}};window.addEventListener('keydown',onKey);return()=>window.removeEventListener('keydown',onKey);},[busy]);
 const headline=busy?t.watching:state.stage==='cancelled'?t.cancelled:state.finished?t.complete:t.ready;
 return <main className="utility">
  <section className="watch-panel">
   <Eye active={state.working} progress={state.progress} progressRef={progressRef} description={t.eye}/>
   <div className="progress-label"><span>{headline}</span><strong>{percent}<small>%</small></strong></div>
   <div ref={progressRef} className="progress-track" role="progressbar" aria-label={headline} aria-valuemin={0} aria-valuemax={100} aria-valuenow={percent}><div className="progress-fill" style={{width:`${percent}%`}}/></div>
   <div className="progress-caption"><span aria-live="polite">{state.preparing?t.preparing:state.working?t[state.stage]||t.encoding:state.stage==='cancelled'?t.cancelled:state.finished?t.complete:t.queued}</span><span>{completed} / {state.files.length} {t.files}</span></div>
  </section>
  <section className="queue-panel" aria-label={t.queue}>
   <h1>{t.queue} <span>/{String(state.files.length).padStart(2,'0')}</span></h1>
   {state.files.length?<ol className="queue-list">{state.files.map((f,index)=><li key={f.id} ref={index===current?activeRow:null} className={`file-row ${f.status==='queued'?'queued':''}`}>
    <span className="file-index" aria-hidden="true">{String(index+1).padStart(2,'0')}</span>
    <div className="file-info"><strong title={f.name}>{f.name}</strong><div className="file-meta"><span>{size(f.bytes)}{f.status==='ok'?` → ${size(f.outputBytes)}`:['encoding','verifying'].includes(f.status)?' → …':''}</span><span>{t[f.status]||t.error}</span></div>
     {f.message&&['error','skipped'].includes(f.status)&&<p className="file-message">{f.message}</p>}
    </div>
   </li>)}</ol>:<p className="empty">{t.empty}</p>}
  </section>
  <div className="action-area">
   {state.message&&<p className="notice" role="status">{state.message}</p>}
   <button className="primary" disabled={state.cancelling} onClick={()=>send(busy?'cancel':'done')}><span>{busy?state.cancelling?t.cancelling:t.cancel:t.done}</span><small aria-hidden="true">{busy?'[ ESC ]':'[ ↵ ]'}</small></button>
  </div>
 </main>;
}
createRoot(document.getElementById('root')).render(<App/>);
