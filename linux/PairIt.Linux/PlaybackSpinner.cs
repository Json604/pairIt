using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;
using Avalonia.Threading;
namespace PairIt.Linux;
internal sealed class PlaybackSpinner : Control
{
    private readonly DispatcherTimer timer=new(){Interval=TimeSpan.FromMilliseconds(70)};
    private int frame;
    internal PlaybackSpinner(){Width=18;Height=18;timer.Tick+=(_,_)=>{frame=(frame+1)%12;InvalidateVisual();};}
    protected override void OnAttachedToVisualTree(VisualTreeAttachmentEventArgs e){base.OnAttachedToVisualTree(e);timer.Start();}
    protected override void OnDetachedFromVisualTree(VisualTreeAttachmentEventArgs e){timer.Stop();base.OnDetachedFromVisualTree(e);}
    public override void Render(DrawingContext context){base.Render(context);for(int i=0;i<12;i++){
        double angle=i*Math.PI/6;var pen=new Pen(new SolidColorBrush(Color.FromArgb((byte)(55+((i-frame+12)%12)*18),255,255,255)),2);
        context.DrawLine(pen,new Point(9+Math.Cos(angle)*4,9+Math.Sin(angle)*4),new Point(9+Math.Cos(angle)*8,9+Math.Sin(angle)*8));}}
}
