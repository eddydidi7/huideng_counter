# Mechanical platform resizing/format conversion of imagegen artwork; no redraw.
Add-Type -AssemblyName System.Drawing
$source=[System.Drawing.Image]::FromFile((Join-Path $PSScriptRoot '../assets/branding/manjushri-icon-master.png'))
function IconPng([int]$size,[bool]$opaque){
 $bitmap=[System.Drawing.Bitmap]::new($size,$size)
 $g=[System.Drawing.Graphics]::FromImage($bitmap)
 if($opaque){$g.Clear([System.Drawing.ColorTranslator]::FromHtml('#681725'))}
 $g.InterpolationMode=[System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
 $g.DrawImage($source,0,0,$size,$size)
 $stream=[System.IO.MemoryStream]::new()
 $bitmap.Save($stream,[System.Drawing.Imaging.ImageFormat]::Png)
 $bytes=$stream.ToArray()
 $stream.Dispose();$g.Dispose();$bitmap.Dispose()
 return ,$bytes
}
try{
 $root=Resolve-Path (Join-Path $PSScriptRoot '..')
 foreach($density in @{mdpi=48;hdpi=72;xhdpi=96;xxhdpi=144;xxxhdpi=192}.GetEnumerator()){
  [System.IO.File]::WriteAllBytes((Join-Path $root "android/app/src/main/res/mipmap-$($density.Key)/ic_launcher.png"),(IconPng $density.Value $false))
 }
 $ios=Join-Path $root 'ios/Runner/Assets.xcassets/AppIcon.appiconset'
 $spec=Get-Content (Join-Path $ios 'Contents.json') -Raw | ConvertFrom-Json
 foreach($entry in $spec.images){
  $size=[int]([double]($entry.size.Split('x')[0])*[double]($entry.scale.TrimEnd('x')))
  [System.IO.File]::WriteAllBytes((Join-Path $ios $entry.filename),(IconPng $size $true))
 }
 [System.IO.File]::WriteAllBytes((Join-Path $root 'assets/branding/manjushri-icon-1024.png'),(IconPng 1024 $false))
 $sizes=@(16,24,32,48,64,128,256)
 $pngs=@(foreach($n in $sizes){ ,(IconPng $n $false) })
 $stream=[System.IO.MemoryStream]::new();$writer=[System.IO.BinaryWriter]::new($stream)
 $writer.Write([uint16]0);$writer.Write([uint16]1);$writer.Write([uint16]$sizes.Count)
 $offset=6+16*$sizes.Count
 for($i=0;$i -lt $sizes.Count;$i++){
  $n=$sizes[$i];$dimension=if($n -eq 256){0}else{$n}
  $writer.Write([byte]$dimension);$writer.Write([byte]$dimension);$writer.Write([byte]0);$writer.Write([byte]0)
  $writer.Write([uint16]1);$writer.Write([uint16]32);$writer.Write([uint32]$pngs[$i].Length);$writer.Write([uint32]$offset)
  $offset+=$pngs[$i].Length
 }
 foreach($bytes in $pngs){$writer.Write([byte[]]$bytes)}
 [System.IO.File]::WriteAllBytes((Join-Path $root 'windows/runner/resources/app_icon.ico'),$stream.ToArray())
 $writer.Dispose();$stream.Dispose()
}finally{$source.Dispose()}
