import 'dart:convert';
import 'dart:io';
import 'package:isar/isar.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:trivia_web_service/data.dart';
import 'package:shelf_multipart/form_data.dart';

Future<void> main(List<String> arguments) async {
  var app = Router();

  // Security / Settings
  var token = '<enter your own token>';
  var port = 8080;
  var lastException;
  var basePath = "/";

    // Setup Database
    Directory dbDir = Directory.current;
    var dataDir = Directory("${dbDir.path}/data");
    if (!dataDir.existsSync()) {
      dataDir.createSync();
    }
    if(dataDir.path.startsWith("/var/www")) {
      basePath = "/trivia/";
    }
  try {
    final isar = await Isar.open(
      [QuestionSchema, CategorySchema],
      directory: dataDir.path,
    );

    // Read the settings
    print("Settings: ");
    File settingsFile = new File("${dbDir.path}/settings.json");
    print("  Looking for settings in: ${settingsFile.path}");
    if(settingsFile.existsSync()) {
      var settings = jsonDecode(settingsFile.readAsStringSync());
      if (settings["token"] != null) {
        token = settings["token"];
      }
      if (settings["port"] != null) {
        port = int.parse(settings["port"]);
      }
    } else {
      print("  No settings file found");
    }
    print("  token: $token");
    print("  port: $port");

    /*
  // Temporary ... load questions
  for(var tossup in tossUps) {
    print(tossup.question);

    var categoryName = tossup.category;
    var question = Question();
    question.question = tossup.question;
    question.answer = tossup.answer;

    // Look up or create the category
    question.category =
        isar.categorys.filter().nameEqualTo(categoryName).findFirstSync();
    question.category ??= Category()
      ..name = categoryName;

    await isar.writeTxn(() async {
      if(question.category != null) {
        question.category!.lastUpdated = DateTime.now();
        await isar.categorys.put(question.category!);
        question.categoryId = question.category!.id;
      }
      question.lastUpdated = DateTime.now();
      await isar.questions.put(question);
    });

  }
*/

    /*  Update/Insert a new question
     -------------------------------------------  */
    app.post('${basePath}update', (Request request) async {
      // Make sure not just anyone can change the questions
      var userToken = request.headers["Authorization"];
      if (userToken != "Bearer $token") {
        return Response.unauthorized("Invalid access");
      }

      // Make sure the form parameters are there
      if (!request.isMultipartForm) {
        return Response.badRequest(body: "No form parameters");
      }

      // Parse the details
      var question = Question();
      String? categoryName;
      await for (final formData in request.multipartFormData) {
        switch (formData.name) {
          case "category":
            categoryName = await formData.part.readString();
            break;
          case "question":
            question.question = await formData.part.readString();
            break;
          case "answer":
            question.answer = await formData.part.readString();
            break;
          case "source":
            question.source = await formData.part.readString();
            break;
          case "id":
            question.id = int.parse(await formData.part.readString());
            break;
        }
      }

      if (question.id != null && question.id > 0) {
        var existingQuestion = isar.questions.getSync(question.id);
        if (existingQuestion == null) {
          return Response.badRequest(
              body: "Could not find question ID #${question.id}");
        }
        if (question.question != null) {
          existingQuestion.question = question.question;
        }
        if (question.answer != null) {
          existingQuestion.answer = question.answer;
        }
        if (question.source != null) {
          existingQuestion.source = question.source;
        }
        question = existingQuestion;
      }

      // Look up or create the category
      if (categoryName == null) {
        if (question.categoryId == null) {
          return Response.badRequest(body: "Category not supplied");
        }
      } else {
        question.category =
            isar.categorys.filter().nameEqualTo(categoryName).findFirstSync();
        question.category ??= Category()
          ..name = categoryName;
      }

      await isar.writeTxn(() async {
        if (question.category != null) {
          question.category!.lastUpdated = DateTime.now();
          await isar.categorys.put(question.category!);
          question.categoryId = question.category!.id;
        }
        question.lastUpdated = DateTime.now();
        await isar.questions.put(question);
      });

      return Response.ok(jsonEncode({
        "id": question.id,
        "question": question.question,
        "answer": question.answer,
      }),
        headers: {
          'Content-type': 'application/json'
        },
      );
    });

    /*  List Questions
     -------------------------------------------  */
    app.get('${basePath}questions', (Request request) async {
      // parse the parameters
      var pageSize = 20;
      if (request.url.queryParameters["pageSize"] != null) {
        pageSize = int.parse(request.url.queryParameters["pageSize"]!);
        if (pageSize > 100) {
          pageSize = 100;
        }
      }
      var offset = 0;
      if (request.url.queryParameters["page"] != null) {
        offset = int.parse(request.url.queryParameters["page"]!) * pageSize;
      }
      var categoryId = request.url.queryParameters["categoryId"];
      var categoryName = request.url.queryParameters["categoryName"];

      FilterCondition? filter;
      if (categoryId != null) {
        filter = FilterCondition.equalTo(
            property: "categoryId", value: int.parse(categoryId));
      } else if (categoryName != null) {
        var category = await isar.categorys.filter()
            .nameEqualTo(categoryName)
            .findFirst();
        if (category == null) {
          return Response.badRequest(body: "Category not found: $categoryName");
        }
        filter =
            FilterCondition.equalTo(property: "categoryId", value: category.id);
      }

      // Get stats
      var totalNumber = await isar.questions.count();
      var pages = (totalNumber / pageSize).ceil();

      // start building the query
      final queryResult = await isar.questions.buildQuery(
        filter: filter,
        offset: offset,
        limit: pageSize,
      ).findAll();

      var list = queryResult.map((question) {
        if (question.categoryId == null) {
          question.category = Category()
            ..name = "";
        } else {
          question.category = isar.categorys.getSync(question.categoryId!);
        }
        return {
          "id": question.id,
          "category": question.category!.name,
          "question": question.question,
          "answer": question.answer,
          "source": question.source,
          "created": question.created.toString(),
          "lastUpdated": question.lastUpdated.toString(),
        };
      }).toList();
      return Response.ok(jsonEncode({
        "list": list,
        "totalNumber": totalNumber,
        "pages": pages,
      }),
        headers: {
          'Content-type': 'application/json'
        },);
    });

    /*  List Categories
     -------------------------------------------  */
    app.get('${basePath}categories', (Request request) async {
      // Get stats
      var totalNumber = await isar.categorys.count();
      var pages = 1;

      var list = (await isar.categorys.where().findAll())
          .map((category) {
        return {
          "id": category.id,
          "name": category.name,
          "created": category.created.toString(),
          "lastUpdated": category.lastUpdated.toString(),
        };
      }).toList();
      return Response.ok(jsonEncode({
        "list": list,
        "totalNumber": totalNumber,
        "pages": pages,
      }),
        headers: {
          'Content-type': 'application/json'
        },);
    });
  } catch(e) {
    lastException = e;
  }

  /*  Get info
     -------------------------------------------  */
  app.get('${basePath}info', (Request request) async {
    return Response.ok(jsonEncode({
      "dataDir": dataDir.path,
      "lastException": lastException == null ? "" : lastException.toString(),
    }),
      headers: {
        'Content-type':'application/json'
      },);
  });

  var server = await io.serve(app, 'localhost', port);
}
