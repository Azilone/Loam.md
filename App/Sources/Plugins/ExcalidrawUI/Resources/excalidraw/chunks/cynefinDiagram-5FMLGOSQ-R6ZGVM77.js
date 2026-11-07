import{a as yt,b as It}from"./chunk-RWGMXJWA.js";import{a as pt,b as Nt}from"./chunk-CIQC7SF6.js";import{a as ut,c as Wt}from"./chunk-MXWZ6MYD.js";import"./chunk-RD36RQHS.js";import"./chunk-SF6E4SGB.js";import"./chunk-RDM7PJ4P.js";import"./chunk-YY367DEP.js";import"./chunk-XR7OIDD6.js";import"./chunk-XWRUYNIB.js";import"./chunk-HI3D27E5.js";import"./chunk-HDAUMXR7.js";import"./chunk-TFJGNFGV.js";import"./chunk-5UKK6O3B.js";import"./chunk-WYCXAFS6.js";import"./chunk-QFLTCTCS.js";import"./chunk-5IIIWMJS.js";import"./chunk-TJDOGHBN.js";import"./chunk-ONQDDBRX.js";import"./chunk-KN3JSF5I.js";import{p as X,v as Pt}from"./chunk-PMTVNEHE.js";import"./chunk-Y6J7MZKI.js";import{$ as mt,Q as rt,V as it,W as st,X as ct,Y as lt,Z as dt,_ as ft,ha as Lt,k as Q,m as at,w as O}from"./chunk-YXTWOKGE.js";import{b as E,d as zt}from"./chunk-OZJ45I45.js";import{a as r,c as Mt}from"./chunk-ZN4ZVHAX.js";import{b as St}from"./chunk-5WQQVLRT.js";function H(t){let e=t+1831565813|0;return e=Math.imul(e^e>>>15,e|1),e^=e+Math.imul(e^e>>>7,e|61),((e^e>>>14)>>>0)/4294967296}function gt(t){let e=0;for(let n=0;n<t.length;n++){let o=t.charCodeAt(n);e=(e<<5)-e+o,e|=0}return e}function $t(t,e){return typeof t=="number"&&Number.isFinite(t)&&t!==0?t:gt(e)}function bt(t,e,n,o){let c=t/2,m=o??t*.015,v=7,W=e/v,d=[];for(let a=0;a<=v;a++){let p=H(n+a*17)*m*2-m;d.push({x:c+p,y:a*W})}let D=`M${d[0].x},${d[0].y}`;for(let a=0;a<d.length-1;a++){let p=d[a],s=d[a+1],f=(p.y+s.y)/2,b=a%2===0?1:-1,h=m*1.5*b*H(n+a*31+7),R=p.x+h,F=f,V=s.x-h;D+=` C${R},${F} ${V},${f} ${s.x},${s.y}`}return D}function wt(t,e,n,o){let c=e/2,m=o??e*.015,v=7,W=t/v,d=[];for(let a=0;a<=v;a++){let p=H(n+a*23)*m*2-m;d.push({x:a*W,y:c+p})}let D=`M${d[0].x},${d[0].y}`;for(let a=0;a<d.length-1;a++){let p=d[a],s=d[a+1],f=(p.x+s.x)/2,b=a%2===0?1:-1,h=m*1.5*b*H(n+a*37+11),R=f,F=p.y+h,V=f,z=s.y-h;D+=` C${R},${F} ${V},${z} ${s.x},${s.y}`}return D}function Ct(t,e){let n=t/2,o=e*.5,c=e,m=t*.03;return[`M${n},${o}`,`C${n+m},${o+(c-o)*.2}`,`${n-m*1.5},${o+(c-o)*.55}`,`${n+m*.5},${o+(c-o)*.75}`,`C${n-m},${o+(c-o)*.85}`,`${n+m*.3},${o+(c-o)*.95}`,`${n},${c}`].join(" ")}function vt(t,e,n,o){return[`M${t-n},${e}`,`A${n},${o} 0 1,1 ${t+n},${e}`,`A${n},${o} 0 1,1 ${t-n},${e}`,"Z"].join(" ")}var xt,G,Rt,Ft,Vt,_t,Et,Ht,j,Gt,Yt,ht,Ot,Xt,Z,jt,qt,Ut,Qt,Zt,ie,Jt=St(()=>{It();Nt();Pt();Lt();zt();Mt();Wt();xt=r(()=>({domains:new Map,transitions:[]}),"createDefaultData"),G=xt(),Rt=r(()=>G.domains,"getDomains"),Ft=r(()=>G.transitions,"getTransitions"),Vt=r(t=>{if(t)for(let e of t){let n=e.domain,o=(e.items??[]).map(c=>({label:c.label}));G.domains.set(n,{name:n,items:o})}},"setDomains"),_t=r(t=>{t&&(G.transitions=t.filter(e=>e.from===e.to?(E.warn(`Cynefin: self-loop transition on domain "${e.from}" is not meaningful and will be skipped.`),!1):!0).map(e=>({from:e.from,to:e.to,label:e.label||void 0})))},"setTransitions"),Et=r(()=>X({...at.cynefin,...O().cynefin}),"getConfig"),Ht=r(()=>{it(),G=xt()},"clear"),j={getDomains:Rt,getTransitions:Ft,setDomains:Vt,setTransitions:_t,getConfig:Et,clear:Ht,setAccTitle:st,getAccTitle:ct,setDiagramTitle:ft,getDiagramTitle:mt,getAccDescription:dt,setAccDescription:lt},Gt=r(t=>{yt(t,j),j.setDomains(t.domains),j.setTransitions(t.transitions)},"populate"),Yt={parse:r(async t=>{let e=await ut("cynefin",t);E.debug(e),Gt(e)},"parse")};r(H,"seededRandom");r(gt,"hashString");r($t,"resolveSeed");r(bt,"generateFoldPath");r(wt,"generateHorizontalBoundary");r(Ct,"generateCliffPath");r(vt,"generateConfusionPath");ht={complex:{model:"Probe \u2192 Sense \u2192 Respond",practice:"Emergent Practices"},complicated:{model:"Sense \u2192 Analyse \u2192 Respond",practice:"Good Practices"},clear:{model:"Sense \u2192 Categorise \u2192 Respond",practice:"Best Practices"},chaotic:{model:"Act \u2192 Sense \u2192 Respond",practice:"Novel Practices"},confusion:{model:"",practice:"Disorder"}},Ot=r((t,e)=>{let n=t/2,o=e/2;return{complex:{cx:n/2,cy:o/2,x:0,y:0,w:n,h:o},complicated:{cx:n+n/2,cy:o/2,x:n,y:0,w:n,h:o},chaotic:{cx:n/2,cy:o+o/2,x:0,y:o,w:n,h:o},clear:{cx:n+n/2,cy:o+o/2,x:n,y:o,w:n,h:o},confusion:{cx:n,cy:o,x:n*.7,y:o*.7,w:n*.6,h:o*.6}}},"getDomainLayouts"),Xt=r(()=>{let t=Q(),e=O();return X(t,e.themeVariables).cynefin},"getCynefinDomainColors"),Z=3,jt=r((t,e,n,o)=>{let c=o.db,m=c.getDomains(),v=c.getTransitions(),W=c.getDiagramTitle(),d=c.getAccTitle(),D=c.getAccDescription(),a=c.getConfig(),p=Xt();E.debug("Rendering Cynefin diagram");let s=a.width,f=a.height,b=a.padding,h=a.showDomainDescriptions,R=a.boundaryAmplitude,F=s+b*2,V=f+b*2,z={complex:p.complexBg,complicated:p.complicatedBg,clear:p.clearBg,chaotic:p.chaoticBg,confusion:p.confusionBg},k=pt(e);rt(k,V,F,a.useMaxWidth??!0),k.attr("viewBox",`0 0 ${F} ${V}`),d&&k.append("title").text(d),D&&k.append("desc").text(D);let T=k.append("g").attr("transform",`translate(${b}, ${b})`),_=Ot(s,f),J=$t(a.seed,e),Dt=T.append("g").attr("class","cynefin-backgrounds"),q=["complex","complicated","chaotic","clear"];for(let l of q){let i=_[l];Dt.append("rect").attr("class","cynefinDomain").attr("x",i.x).attr("y",i.y).attr("width",i.w).attr("height",i.h).attr("fill",z[l]).attr("fill-opacity",.4).attr("stroke","none")}let U=T.append("g").attr("class","cynefin-boundaries");U.append("path").attr("class","cynefinBoundary").attr("d",bt(s,f,J,R)).attr("fill","none"),U.append("path").attr("class","cynefinBoundary").attr("d",wt(s,f,J+100,R)).attr("fill","none"),U.append("path").attr("class","cynefinCliff").attr("d",Ct(s,f)).attr("fill","none");let kt=s*.15,Tt=f*.15;T.append("path").attr("class","cynefinConfusion").attr("d",vt(s/2,f/2,kt,Tt)).attr("fill",z.confusion).attr("fill-opacity",.5);let K=T.append("g").attr("class","cynefin-labels");for(let l of q){let i=_[l];K.append("text").attr("class","cynefinDomainLabel").attr("x",i.cx).attr("y",h?i.cy-30:i.cy).attr("text-anchor","middle").attr("dominant-baseline","middle").text(l.charAt(0).toUpperCase()+l.slice(1))}if(K.append("text").attr("class","cynefinDomainLabel").attr("x",s/2).attr("y",h?f/2-10:f/2).attr("text-anchor","middle").attr("dominant-baseline","middle").text("Confusion"),h){let l=T.append("g").attr("class","cynefin-subtitles");for(let i of q){let u=_[i],y=ht[i];l.append("text").attr("class","cynefinSubtitle").attr("x",u.cx).attr("y",u.cy-10).attr("text-anchor","middle").attr("dominant-baseline","middle").text(y.model),l.append("text").attr("class","cynefinSubtitle").attr("x",u.cx).attr("y",u.cy+5).attr("text-anchor","middle").attr("dominant-baseline","middle").text(y.practice)}l.append("text").attr("class","cynefinSubtitle").attr("x",s/2).attr("y",f/2+8).attr("text-anchor","middle").attr("dominant-baseline","middle").text(ht.confusion.practice)}let tt=T.append("g").attr("class","cynefin-items"),A=26,et=10,At=["complex","complicated","chaotic","clear","confusion"];for(let l of At){let i=m.get(l);if(!i||i.items.length===0)continue;let u=_[l],y=l==="confusion",L=i.items,N=0;y&&i.items.length>Z&&(N=i.items.length-Z,L=i.items.slice(0,Z));let B;if(y){let g=h?22:14;B=u.cy+g}else B=u.cy+(h?25:15);if([...L].forEach((g,S)=>{let w=B+S*(A+4),M=tt.append("g"),P=M.append("text").attr("class","cynefinItemText").attr("x",0).attr("y",A/2).attr("text-anchor","middle").attr("dominant-baseline","central").text(g.label),$=g.label.length*7,x=P.node();if(x&&typeof x.getBBox=="function"){let Y=x.getBBox();Y.width>0&&($=Y.width)}let C=$+et*2,I=u.cx-C/2;M.attr("transform",`translate(${I}, ${w})`),M.insert("rect","text").attr("class","cynefinItem").attr("x",0).attr("y",0).attr("width",C).attr("height",A).attr("rx",4).attr("ry",4).attr("fill",z[l]).attr("fill-opacity",.95),P.attr("x",C/2).attr("y",A/2)}),N>0){let g=B+L.length*(A+4),S=`+${N} more`,w=tt.append("g"),M=w.append("text").attr("class","cynefinItemText").attr("x",0).attr("y",A/2).attr("text-anchor","middle").attr("dominant-baseline","central").text(S),P=S.length*7,$=M.node();if($&&typeof $.getBBox=="function"){let I=$.getBBox();I.width>0&&(P=I.width)}let x=P+et*2,C=u.cx-x/2;w.attr("transform",`translate(${C}, ${g})`),w.insert("rect","text").attr("class","cynefinItemOverflow").attr("x",0).attr("y",0).attr("width",x).attr("height",A).attr("rx",4).attr("ry",4).attr("fill",z[l]).attr("fill-opacity",.6),M.attr("x",x/2).attr("y",A/2)}}if(v.length>0){let l=k.select("defs").empty()?k.append("defs"):k.select("defs"),i=`cynefin-arrow-${e}`;l.append("marker").attr("id",i).attr("viewBox","0 0 10 10").attr("refX",9).attr("refY",5).attr("markerWidth",6).attr("markerHeight",6).attr("orient","auto-start-reverse").append("path").attr("d","M 0 0 L 10 5 L 0 10 z").attr("class","cynefinArrowHead");let u=T.append("g").attr("class","cynefin-arrows");v.forEach(y=>{let L=_[y.from],N=_[y.to];if(!L||!N)return;if(y.from===y.to){E.warn(`Cynefin renderer: skipping self-loop on domain "${y.from}"`);return}let B=L.cx,g=L.cy,S=N.cx,w=N.cy,M=(B+S)/2,P=(g+w)/2,$=S-B,x=w-g,C=Math.sqrt($*$+x*x),I=C*.15,Y=-x/C,Bt=$/C,nt=M+Y*I,ot=P+Bt*I;u.append("path").attr("class","cynefinArrowLine").attr("d",`M${B},${g} Q${nt},${ot} ${S},${w}`).attr("fill","none").attr("marker-end",`url(#${i})`),y.label&&u.append("text").attr("class","cynefinArrowLabel").attr("x",nt).attr("y",ot-6).attr("text-anchor","middle").attr("dominant-baseline","auto").text(y.label)})}W&&T.append("text").attr("class","cynefinTitle").attr("x",s/2).attr("y",-b/2).attr("text-anchor","middle").attr("dominant-baseline","middle").text(W)},"draw"),qt={draw:jt},Ut=r(()=>{let t=Q(),e=O();return X(t,e.themeVariables).cynefin},"getCynefinTheme"),Qt=r(()=>{let t=Ut();return`
	.cynefinDomain {
		stroke: none;
	}
	.cynefinDomainLabel {
		font-size: ${t.domainFontSize}px;
		font-weight: bold;
		fill: ${t.labelColor};
	}
	.cynefinSubtitle {
		font-size: ${t.itemFontSize-1}px;
		fill: ${t.textColor};
		font-style: italic;
	}
	.cynefinItem {
		fill-opacity: 0.95;
		stroke: ${t.boundaryColor};
		stroke-width: 1;
	}
	.cynefinItemText {
		font-size: ${t.itemFontSize}px;
		fill: ${t.textColor};
	}
	.cynefinItemOverflow {
		fill-opacity: 0.6;
		stroke: ${t.boundaryColor};
		stroke-width: 1;
		stroke-dasharray: 3 2;
	}
	.cynefinBoundary {
		stroke: ${t.boundaryColor};
		stroke-width: ${t.boundaryWidth};
		stroke-dasharray: 6 3;
	}
	.cynefinCliff {
		stroke: ${t.cliffColor};
		stroke-width: ${t.cliffWidth};
	}
	.cynefinConfusion {
		stroke: ${t.boundaryColor};
		stroke-width: 1.5;
		stroke-dasharray: 4 2;
	}
	.cynefinArrowLine {
		stroke: ${t.arrowColor};
		stroke-width: ${t.arrowWidth};
		fill: none;
	}
	.cynefinArrowHead {
		fill: ${t.arrowColor};
		stroke: none;
	}
	.cynefinArrowLabel {
		font-size: ${t.itemFontSize-1}px;
		fill: ${t.textColor};
	}
	.cynefinTitle {
		font-size: ${t.domainFontSize+2}px;
		font-weight: bold;
		fill: ${t.labelColor};
	}
	`},"styles"),Zt=Qt,ie={parser:Yt,db:j,renderer:qt,styles:Zt}});Jt();export{ie as diagram};
