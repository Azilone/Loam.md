import{a as F,b as q}from"./chunk-RWGMXJWA.js";import{a as E,b as Y}from"./chunk-CIQC7SF6.js";import{a as D,c as J}from"./chunk-MXWZ6MYD.js";import"./chunk-RD36RQHS.js";import"./chunk-SF6E4SGB.js";import"./chunk-RDM7PJ4P.js";import"./chunk-YY367DEP.js";import"./chunk-XR7OIDD6.js";import"./chunk-XWRUYNIB.js";import"./chunk-HI3D27E5.js";import"./chunk-HDAUMXR7.js";import"./chunk-TFJGNFGV.js";import"./chunk-5UKK6O3B.js";import"./chunk-WYCXAFS6.js";import"./chunk-QFLTCTCS.js";import"./chunk-5IIIWMJS.js";import"./chunk-TJDOGHBN.js";import"./chunk-ONQDDBRX.js";import"./chunk-KN3JSF5I.js";import{p as y,v as Z}from"./chunk-PMTVNEHE.js";import"./chunk-Y6J7MZKI.js";import{$ as _,Q as L,V as T,W as S,X as k,Y as O,Z as R,_ as I,ha as N,k as A,m as M,w as b}from"./chunk-YXTWOKGE.js";import{b as C,d as K}from"./chunk-OZJ45I45.js";import{a as i,c as X}from"./chunk-ZN4ZVHAX.js";import{b as U}from"./chunk-5WQQVLRT.js";function G(a,t,e,r,n,l,c){let s=t.length,o=Math.min(c.width,c.height)/2;e.forEach((d,p)=>{if(d.entries.length!==s)return;let u=d.entries.map((m,h)=>{let v=2*Math.PI*h/s-Math.PI/2,f=B(m,r,n,o),H=f*Math.cos(v),j=f*Math.sin(v);return{x:H,y:j}});l==="circle"?a.append("path").attr("d",W(u,c.curveTension)).attr("class",`radarCurve-${p}`):l==="polygon"&&a.append("polygon").attr("points",u.map(m=>`${m.x},${m.y}`).join(" ")).attr("class",`radarCurve-${p}`)})}function B(a,t,e,r){let n=Math.min(Math.max(a,t),e);return r*(n-t)/(e-t)}function W(a,t){let e=a.length,r=`M${a[0].x},${a[0].y}`;for(let n=0;n<e;n++){let l=a[(n-1+e)%e],c=a[n],s=a[(n+1)%e],o=a[(n+2)%e],d={x:c.x+(s.x-l.x)*t,y:c.y+(s.y-l.y)*t},p={x:s.x-(o.x-c.x)*t,y:s.y-(o.y-c.y)*t};r+=` C${d.x},${d.y} ${p.x},${p.y} ${s.x},${s.y}`}return`${r} Z`}function V(a,t,e,r){if(!e)return;let n=(r.width/2+r.marginRight)*3/4,l=-(r.height/2+r.marginTop)*3/4,c=20;t.forEach((s,o)=>{let d=a.append("g").attr("transform",`translate(${n}, ${l+o*c})`);d.append("rect").attr("width",12).attr("height",12).attr("class",`radarLegendBox-${o}`),d.append("text").attr("x",16).attr("y",0).attr("class","radarLegendText").text(s.label)})}var x,w,P,g,Q,tt,z,et,at,rt,nt,st,ot,it,$,lt,ct,dt,ut,pt,mt,gt,xt,ht,vt,Lt,$t=U(()=>{q();Y();Z();N();K();X();J();x={showLegend:!0,ticks:5,max:null,min:0,graticule:"circle"},w=32,P={axes:[],curves:[],options:x},g=structuredClone(P),Q=M.radar,tt=i(()=>y({...Q,...b().radar}),"getConfig"),z=i(()=>g.axes,"getAxes"),et=i(()=>g.curves,"getCurves"),at=i(()=>g.options,"getOptions"),rt=i(a=>{g.axes=a.map(t=>({name:t.name,label:t.label??t.name}))},"setAxes"),nt=i(a=>{g.curves=a.map(t=>({name:t.name,label:t.label??t.name,entries:st(t.entries)}))},"setCurves"),st=i(a=>{if(a[0].axis==null)return a.map(e=>e.value);let t=z();if(t.length===0)throw new Error("Axes must be populated before curves for reference entries");return t.map(e=>{let r=a.find(n=>n.axis?.$refText===e.name);if(r===void 0)throw new Error("Missing entry for axis "+e.label);return r.value})},"computeCurveEntries"),ot=i(a=>{let t=a.reduce((e,r)=>(e[r.name]=r,e),{});g.options={showLegend:t.showLegend?.value??x.showLegend,ticks:t.ticks?.value??x.ticks,max:t.max?.value??x.max,min:t.min?.value??x.min,graticule:t.graticule?.value??x.graticule},g.options.ticks>w&&(C.warn(`Radar diagram ticks (${g.options.ticks}) exceeds maximum allowed (${w}). Using ${w} instead.`),g.options.ticks=w)},"setOptions"),it=i(()=>{T(),g=structuredClone(P)},"clear"),$={getAxes:z,getCurves:et,getOptions:at,setAxes:rt,setCurves:nt,setOptions:ot,getConfig:tt,clear:it,setAccTitle:S,getAccTitle:k,setDiagramTitle:I,getDiagramTitle:_,getAccDescription:R,setAccDescription:O},lt=i(a=>{F(a,$);let{axes:t,curves:e,options:r}=a;$.setAxes(t),$.setCurves(e),$.setOptions(r)},"populate"),ct={parse:i(async a=>{let t=await D("radar",a);C.debug(t),lt(t)},"parse")},dt=i((a,t,e,r)=>{let n=r.db,l=n.getAxes(),c=n.getCurves(),s=n.getOptions(),o=n.getConfig(),d=n.getDiagramTitle(),p=E(t),u=ut(p,o),m=s.max??Math.max(...c.map(f=>Math.max(...f.entries))),h=s.min,v=Math.min(o.width,o.height)/2;pt(u,l,v,s.ticks,s.graticule),mt(u,l,v,o),G(u,l,c,h,m,s.graticule,o),V(u,c,s.showLegend,o),u.append("text").attr("class","radarTitle").text(d).attr("x",0).attr("y",-o.height/2-o.marginTop)},"draw"),ut=i((a,t)=>{let e=t.width+t.marginLeft+t.marginRight,r=t.height+t.marginTop+t.marginBottom,n={x:t.marginLeft+t.width/2,y:t.marginTop+t.height/2};return L(a,r,e,t.useMaxWidth??!0),a.attr("viewBox",`0 0 ${e} ${r}`).attr("overflow","visible"),a.append("g").attr("transform",`translate(${n.x}, ${n.y})`)},"drawFrame"),pt=i((a,t,e,r,n)=>{if(n==="circle")for(let l=0;l<r;l++){let c=e*(l+1)/r;a.append("circle").attr("r",c).attr("class","radarGraticule")}else if(n==="polygon"){let l=t.length;for(let c=0;c<r;c++){let s=e*(c+1)/r,o=t.map((d,p)=>{let u=2*p*Math.PI/l-Math.PI/2,m=s*Math.cos(u),h=s*Math.sin(u);return`${m},${h}`}).join(" ");a.append("polygon").attr("points",o).attr("class","radarGraticule")}}},"drawGraticule"),mt=i((a,t,e,r)=>{let n=t.length;for(let l=0;l<n;l++){let c=t[l].label,s=2*l*Math.PI/n-Math.PI/2,o=Math.cos(s),d=Math.sin(s);a.append("line").attr("x1",0).attr("y1",0).attr("x2",e*r.axisScaleFactor*o).attr("y2",e*r.axisScaleFactor*d).attr("class","radarAxisLine");let p=o>.01?"start":o<-.01?"end":"middle",u=d>.01?"hanging":d<-.01?"auto":"central",m=4;a.append("text").text(c).attr("x",e*r.axisLabelFactor*o+m*o).attr("y",e*r.axisLabelFactor*d+m*d).attr("text-anchor",p).attr("dominant-baseline",u).attr("class","radarAxisLabel")}},"drawAxes");i(G,"drawCurves");i(B,"relativeRadius");i(W,"closedRoundCurve");i(V,"drawLegend");gt={draw:dt},xt=i((a,t)=>{let e="";for(let r=0;r<a.THEME_COLOR_LIMIT;r++){let n=a[`cScale${r}`];e+=`
		.radarCurve-${r} {
			color: ${n};
			fill: ${n};
			fill-opacity: ${t.curveOpacity};
			stroke: ${n};
			stroke-width: ${t.curveStrokeWidth};
		}
		.radarLegendBox-${r} {
			fill: ${n};
			fill-opacity: ${t.curveOpacity};
			stroke: ${n};
		}
		`}return e},"genIndexStyles"),ht=i(a=>{let t=A(),e=b(),r=y(t,e.themeVariables),n=y(r.radar,a);return{themeVariables:r,radarOptions:n}},"buildRadarStyleOptions"),vt=i(({radar:a}={})=>{let{themeVariables:t,radarOptions:e}=ht(a);return`
	.radarTitle {
		font-size: ${t.fontSize};
		color: ${t.titleColor};
		dominant-baseline: hanging;
		text-anchor: middle;
	}
	.radarAxisLine {
		stroke: ${e.axisColor};
		stroke-width: ${e.axisStrokeWidth};
	}
	.radarAxisLabel {
		font-size: ${e.axisLabelFontSize}px;
		color: ${e.axisColor};
	}
	.radarGraticule {
		fill: ${e.graticuleColor};
		fill-opacity: ${e.graticuleOpacity};
		stroke: ${e.graticuleColor};
		stroke-width: ${e.graticuleStrokeWidth};
	}
	.radarLegendText {
		text-anchor: start;
		font-size: ${e.legendFontSize}px;
		dominant-baseline: hanging;
	}
	${xt(t,e)}
	`},"styles"),Lt={parser:ct,db:$,renderer:gt,styles:vt}});$t();export{Lt as diagram};
