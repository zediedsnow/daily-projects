using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;

namespace Cubist;

/// <summary>Terminal and SVG renderings of a cube.</summary>
public static class Render
{
    // U white, R red, F green, D yellow, L orange, B blue
    static readonly string[] Hex = { "#f4f4f0", "#d7263d", "#1b998b", "#ffd23f", "#f46036", "#2e5eaa" };
    static readonly int[] Ansi = { 255, 160, 35, 220, 208, 26 };

    /// <summary>Unfolded net in the terminal using 256-colour backgrounds.</summary>
    public static string Net(CubieCube c, bool color = true)
    {
        var f = c.ToFacelets();
        var sb = new StringBuilder();
        string Cell(int idx) => color ? $"\x1b[48;5;{Ansi[f[idx]]}m  \x1b[0m" : CubieCube.FaceNames[f[idx]] + " ";
        string Blank = "      ";
        for (int r = 0; r < 3; r++) { sb.Append(Blank); for (int col = 0; col < 3; col++) sb.Append(Cell(r * 3 + col)); sb.Append('\n'); }
        int[] order = { 4, 2, 1, 5 }; // L F R B
        for (int r = 0; r < 3; r++)
        {
            foreach (var face in order) for (int col = 0; col < 3; col++) sb.Append(Cell(face * 9 + r * 3 + col));
            sb.Append('\n');
        }
        for (int r = 0; r < 3; r++) { sb.Append(Blank); for (int col = 0; col < 3; col++) sb.Append(Cell(27 + r * 3 + col)); sb.Append('\n'); }
        return sb.ToString();
    }

    static string F(double v) => v.ToString("0.##", CultureInfo.InvariantCulture);

    /// <summary>An isometric cube showing the U, F and R faces, as SVG polygons.</summary>
    public static string IsoCube(CubieCube c, double ox, double oy, double s)
    {
        var f = c.ToFacelets();
        var sb = new StringBuilder();
        double cos = Math.Cos(Math.PI / 6), sin = 0.5;
        (double, double) P(double x, double y, double z) => (ox + (x - z) * cos * s, oy + ((x + z) * sin - y) * s);
        void Quad(int color, (double x, double y, double z)[] pts)
        {
            sb.Append("<polygon points=\"");
            foreach (var (x, y, z) in pts) { var (px, py) = P(x, y, z); sb.Append(F(px)).Append(',').Append(F(py)).Append(' '); }
            sb.Append($"\" fill=\"{Hex[color]}\" stroke=\"#111\" stroke-width=\"{F(s * 0.09)}\" stroke-linejoin=\"round\"/>");
        }
        for (int r = 0; r < 3; r++)
            for (int col = 0; col < 3; col++)
            {
                // U face (y = 3): row 0 is the back row
                Quad(f[r * 3 + col], new[] { (col + 0.0, 3.0, r + 0.0), (col + 1.0, 3.0, r + 0.0), (col + 1.0, 3.0, r + 1.0), (col + 0.0, 3.0, r + 1.0) });
                // F face (z = 3)
                double y0 = 3 - r - 1, y1 = 3 - r;
                Quad(f[18 + r * 3 + col], new[] { (col + 0.0, y1, 3.0), (col + 1.0, y1, 3.0), (col + 1.0, y0, 3.0), (col + 0.0, y0, 3.0) });
                // R face (x = 3): column 0 touches the front
                double z0 = 3 - col - 1, z1 = 3 - col;
                Quad(f[9 + r * 3 + col], new[] { (3.0, y1, z1), (3.0, y1, z0), (3.0, y0, z0), (3.0, y0, z1) });
            }
        return sb.ToString();
    }

    /// <summary>A film strip: the scrambled cube followed by the state after every solution move.</summary>
    public static string Filmstrip(CubieCube start, IList<int> solution, string title, string subtitle)
    {
        const int perRow = 8; const double cell = 132, s = 17;
        int frames = solution.Count + 1;
        int rows = (frames + perRow - 1) / perRow;
        double w = perRow * cell + 40, h = rows * (cell + 26) + 110;
        var sb = new StringBuilder();
        sb.Append($"<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{F(w)}\" height=\"{F(h)}\" viewBox=\"0 0 {F(w)} {F(h)}\" font-family=\"ui-monospace,Menlo,Consolas,monospace\">");
        sb.Append($"<rect width=\"100%\" height=\"100%\" fill=\"#14161c\"/>");
        sb.Append($"<text x=\"24\" y=\"42\" fill=\"#eee\" font-size=\"24\" font-weight=\"700\">{Esc(title)}</text>");
        sb.Append($"<text x=\"24\" y=\"70\" fill=\"#9aa\" font-size=\"15\">{Esc(subtitle)}</text>");
        var c = start.Clone();
        for (int i = 0; i < frames; i++)
        {
            if (i > 0) c.Move(solution[i - 1]);
            int row = i / perRow, col = i % perRow;
            double x0 = 20 + col * cell, y0 = 96 + row * (cell + 26);
            sb.Append(IsoCube(c, x0 + cell / 2, y0 + 3 * s + 6, s));
            string label = i == 0 ? "scrambled" : $"{i}. {Moves.Name(solution[i - 1])}";
            string colr = i == frames - 1 ? "#7ee787" : "#ccd";
            sb.Append($"<text x=\"{F(x0 + cell / 2)}\" y=\"{F(y0 + 6 * s + 30)}\" fill=\"{colr}\" font-size=\"15\" text-anchor=\"middle\">{Esc(label)}</text>");
        }
        sb.Append("</svg>");
        return sb.ToString();
    }

    static string Esc(string s) => s.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;");
}
