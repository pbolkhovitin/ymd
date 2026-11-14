/* Интеграционная проверка приватного runtime, в приложение не включается. */
#include <gst/gst.h>
#include <gio/gio.h>
#include <stdio.h>

static gboolean reject_untrusted(GstElement *source, GTlsCertificate *certificate,
                                 GTlsCertificateFlags errors, gpointer data) {
    /* Отмечаем конкретный отказ TLS, не отключая проверку сертификатов. */
    *((gboolean *)data) = TRUE;
    return FALSE;
}

int main(int argc, char **argv) {
    gst_init(&argc, &argv);
    const char *elements[] = {"playbin3", "souphttpsrc", "avdec_aac", "flacdec", "mpg123audiodec", "osxaudiosink", NULL};
    for (int i = 0; elements[i]; i++) {
        GstElementFactory *factory = gst_element_factory_find(elements[i]);
        if (!factory) {
            fprintf(stderr, "Не найден элемент: %s\n", elements[i]);
            return 1;
        }
        gst_object_unref(factory);
    }
    GError *error = NULL;
    gboolean certificate_rejected = FALSE;
    const char *description = argc > 1
        ? "souphttpsrc name=source ! fakesink"
        : "audiotestsrc num-buffers=100 ! audioconvert ! audioresample ! osxaudiosink";
    GstElement *pipeline = gst_parse_launch(description, &error);
    if (error) {
        fprintf(stderr, "%s\n", error->message);
        return 2;
    }
    if (argc > 1) {
        GstElement *source = gst_bin_get_by_name(GST_BIN(pipeline), "source");
        GTlsDatabase *database = g_tls_file_database_new(g_getenv("YMD_CA_BUNDLE"), &error);
        if (!database) {
            fprintf(stderr, "Ошибка базы TLS: %s\n", error->message);
            return 3;
        }
        g_object_set(source, "location", argv[1], "tls-database", database, NULL);
        g_signal_connect(source, "accept-certificate", G_CALLBACK(reject_untrusted), &certificate_rejected);
        g_object_unref(database);
        gst_object_unref(source);
    }
    gst_element_set_state(pipeline, GST_STATE_PLAYING);
    GstBus *bus = gst_element_get_bus(pipeline);
    GstMessage *message = gst_bus_timed_pop_filtered(bus, 30 * GST_SECOND, GST_MESSAGE_ERROR | GST_MESSAGE_EOS);
    int result = 0;
    if (!message) {
        fprintf(stderr, "Таймаут пайплайна\n");
        result = 4;
    } else if (GST_MESSAGE_TYPE(message) == GST_MESSAGE_ERROR) {
        gchar *debug = NULL;
        gst_message_parse_error(message, &error, &debug);
        fprintf(stderr, "%s (%s)\n", error->message, debug ? debug : "");
        if (certificate_rejected) fprintf(stderr, "TLS certificate rejected\n");
        g_free(debug);
        g_error_free(error);
        result = 5;
    } else {
        printf("ok: аудиоэлементы найдены, %s завершён с EOS\n", argc > 1 ? "HTTPS" : "звук");
    }
    if (message) gst_message_unref(message);
    gst_element_set_state(pipeline, GST_STATE_NULL);
    gst_object_unref(bus);
    gst_object_unref(pipeline);
    return result;
}
