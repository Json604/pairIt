namespace PairIt.Windows;
internal sealed class PlaybackButton : Button
{
    private readonly System.Windows.Forms.Timer timer=new(){Interval=70};
    private int frame;
    [System.ComponentModel.DesignerSerializationVisibility(System.ComponentModel.DesignerSerializationVisibility.Hidden)]
    internal bool Busy {set {timer.Enabled=value;Invalidate();}}
    internal PlaybackButton(){timer.Tick+=(_,_)=>{frame=(frame+1)%12;Invalidate();};}
    protected override void OnPaint(PaintEventArgs e){base.OnPaint(e);if(!timer.Enabled)return;
        e.Graphics.SmoothingMode=System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
        for(int i=0;i<12;i++){double angle=i*Math.PI/6;using var pen=new Pen(Color.FromArgb(55+((i-frame+12)%12)*18,ForeColor),2);
            e.Graphics.DrawLine(pen,18+(float)Math.Cos(angle)*4,Height/2+(float)Math.Sin(angle)*4,18+(float)Math.Cos(angle)*8,Height/2+(float)Math.Sin(angle)*8);}
    }
    protected override void Dispose(bool disposing){if(disposing)timer.Dispose();base.Dispose(disposing);}
}
