export function renderEye(gazeX,gazeY,openness) {
  const art=[];
  for(let r=0;r<29;r++) {
    let row='';
    for(let c=0;c<69;c++) {
      const x=(c-34)/31,y=(r-14)/11;
      const height=Math.max(0,1-Math.abs(x)**1.65)*.80;
      const d=Math.abs(y)-height*Math.max(.035,openness);
      const noise=((c*37+r*71+c*r*13)%19)/19;
      let ch=' ';
      if(Math.abs(x)<1.02&&Math.abs(d)<.075)ch='▓';
      else if(Math.abs(x)<1&&d<0) {
        const iris=Math.hypot((x-gazeX)/.38,(y-gazeY)/.8);
        const pupil=Math.hypot((x-gazeX)/.16,(y-gazeY)/.37);
        if(pupil<1)ch='█';
        else if(iris<1)ch=iris>.88?'▓':'▧▒╱░□▓'[(c*7+r*3)%6];
        else ch=noise>.84?'·':' ';
        if(((x-gazeX+.1)/.07)**2+((y-gazeY+.27)/.14)**2<1)ch=' ';
      } else if(Math.abs(x)<1&&y<-.9&&y>-1.25+Math.abs(x)*.23&&noise>.42)ch='═';
      else if(Math.abs(x)<.99&&d>.12&&d<.28&&y>0&&noise>.35)ch='·';
      else if(c%4===0&&r%3===0)ch='·';
      row+=ch;
    }
    art.push(row);
  }
  return art.join('\n');
}

