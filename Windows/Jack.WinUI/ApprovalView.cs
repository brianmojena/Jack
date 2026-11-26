using Jack.Core;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Jack.WinUI;

// Tarjeta de una aprobación pendiente. Si el agente pide permiso: Permitir / Denegar y sus opciones. Si hace
// preguntas: un formulario con una entrada por pregunta y "Enviar respuestas".
internal static class ApprovalView
{
    // El detalle de un permiso puede ser enorme (un comando largo, un diff): se acota para no bloquear la ventana.
    private const int DetailLimit = 4000;

    public static FrameworkElement Build(ChatStore store, Guid conversationId, ChatApproval approval)
    {
        var stack = new StackPanel { Spacing = 10 };
        stack.Children.Add(new TextBlock
        {
            Text = approval.Title,
            FontWeight = FontWeights.SemiBold,
            TextWrapping = TextWrapping.Wrap
        });

        if (!string.IsNullOrWhiteSpace(approval.Detail))
        {
            var detail = new TextBlock
            {
                Text = Bounded(approval.Detail),
                Style = (Style)Application.Current.Resources["JackMono"],
                TextWrapping = TextWrapping.Wrap,
                IsTextSelectionEnabled = true
            };
            stack.Children.Add(new ScrollViewer
            {
                MaxHeight = 180,
                HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
                VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                Content = detail
            });
        }

        if (approval.Questions.Count > 0)
        {
            var readers = new List<(string Id, Func<string> Read)>();
            foreach (var question in approval.Questions)
            {
                stack.Children.Add(BuildQuestion(question, readers));
            }
            stack.Children.Add(Row(
                ActionButton("Enviar respuestas", true, () =>
                {
                    var answers = new Dictionary<string, string>();
                    foreach (var (questionId, read) in readers) answers[questionId] = read();
                    store.Answer(conversationId, approval.Id, answers);
                }),
                ActionButton("Denegar", false, () => store.Respond(conversationId, approval.Id, false))));
        }
        else
        {
            var row = Row(
                ActionButton("Permitir", true, () => store.Respond(conversationId, approval.Id, true)),
                ActionButton("Denegar", false, () => store.Respond(conversationId, approval.Id, false)));
            foreach (var choice in approval.Choices)
            {
                var choiceId = choice.Id;
                row.Children.Add(ActionButton(choice.Title, false, () => store.Respond(conversationId, approval.Id, choiceId)));
            }
            stack.Children.Add(row);
        }

        return new Border
        {
            Style = (Style)Application.Current.Resources["JackPanel"],
            Child = stack
        };
    }

    private static FrameworkElement BuildQuestion(ChatInputQuestion question, List<(string Id, Func<string> Read)> readers)
    {
        var panel = new StackPanel { Spacing = 6 };
        if (!string.IsNullOrWhiteSpace(question.Header))
        {
            panel.Children.Add(new TextBlock
            {
                Text = question.Header,
                Style = (Style)Application.Current.Resources["JackCaption"]
            });
        }
        panel.Children.Add(new TextBlock { Text = question.Question, TextWrapping = TextWrapping.Wrap });

        var options = question.Options;
        if (options is null || options.Count == 0)
        {
            if (question.IsSecret == true)
            {
                var secret = new PasswordBox { PlaceholderText = "Respuesta" };
                panel.Children.Add(secret);
                readers.Add((question.Id, () => secret.Password));
            }
            else
            {
                var text = new TextBox { PlaceholderText = "Respuesta" };
                panel.Children.Add(text);
                readers.Add((question.Id, () => text.Text));
            }
        }
        else if (question.MultiSelect == true)
        {
            var boxes = new List<(string Label, CheckBox Box)>();
            foreach (var option in options)
            {
                var box = new CheckBox { Content = OptionContent(option) };
                boxes.Add((option.Label, box));
                panel.Children.Add(box);
            }
            readers.Add((question.Id, () => string.Join(", ",
                boxes.Where(entry => entry.Box.IsChecked == true).Select(entry => entry.Label))));
        }
        else
        {
            // El GroupName agrupa los botones de esta pregunta; cada pregunta tiene su propio panel.
            var radios = new List<(string Label, RadioButton Radio)>();
            foreach (var option in options)
            {
                var radio = new RadioButton { Content = OptionContent(option), GroupName = question.Id };
                radios.Add((option.Label, radio));
                panel.Children.Add(radio);
            }
            readers.Add((question.Id, () => radios.FirstOrDefault(entry => entry.Radio.IsChecked == true).Label ?? ""));
        }
        return panel;
    }

    private static FrameworkElement OptionContent(ChatInputOption option)
    {
        var stack = new StackPanel { Spacing = 2 };
        stack.Children.Add(new TextBlock { Text = option.Label, TextWrapping = TextWrapping.Wrap });
        if (!string.IsNullOrWhiteSpace(option.Description))
        {
            stack.Children.Add(new TextBlock
            {
                Text = option.Description,
                Style = (Style)Application.Current.Resources["JackCaption"]
            });
        }
        return stack;
    }

    private static StackPanel Row(params UIElement[] items)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        foreach (var item in items) row.Children.Add(item);
        return row;
    }

    private static Button ActionButton(string text, bool accent, Action onClick)
    {
        var button = new Button { Content = text };
        if (accent) button.Style = (Style)Application.Current.Resources["AccentButtonStyle"];
        button.Click += (_, _) => onClick();
        return button;
    }

    private static string Bounded(string text) => text.Length <= DetailLimit ? text : text[..DetailLimit] + "\n…";
}
